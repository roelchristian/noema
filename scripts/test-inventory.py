#!/usr/bin/env python3
"""Static Swift test inventory; declarations are not executed runtime cases."""
import argparse
import json
import re
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent


def mask_literals(text):
    """Keep offsets while hiding Swift comments and ordinary/raw string contents."""
    result = list(text)
    i = 0
    while i < len(text):
        start = i
        if text.startswith('//', i):
            end = text.find('\n', i)
            i = len(text) if end < 0 else end
        elif text.startswith('/*', i):
            i += 2
            depth = 1
            while i < len(text) and depth:
                if text.startswith('/*', i):
                    depth += 1
                    i += 2
                elif text.startswith('*/', i):
                    depth -= 1
                    i += 2
                else:
                    i += 1
        else:
            match = re.match(r'(#+)?("""|")', text[i:])
            if not match:
                i += 1
                continue
            hashes = match[1] or ''
            ending = match[2] + hashes
            i += len(match[0])
            while i < len(text):
                if text.startswith('\\' + hashes, i):
                    i += len(hashes) + 2
                elif text.startswith(ending, i):
                    i += len(ending)
                    break
                else:
                    i += 1
            # Retain an opaque value so an array of strings still has elements.
            result[start] = 'x'
            start += 1
        for j in range(start, min(i, len(text))):
            if result[j] != '\n':
                result[j] = ' '
    return ''.join(result)


def split_top_level(expression):
    parts, start, stack = [], 0, []
    for i, char in enumerate(expression):
        if char in '([{':
            stack.append(char)
        elif char in ')]}':
            if stack:
                stack.pop()
        elif char == ',' and not stack:
            parts.append(expression[start:i].strip())
            start = i + 1
    parts.append(expression[start:].strip())
    return [part for part in parts if part]


def closing(text, start):
    depth = 0
    for i in range(start, len(text)):
        if text[i] == '(':
            depth += 1
        elif text[i] == ')':
            depth -= 1
            if depth == 0:
                return i
    raise ValueError('Unbalanced @Test attribute')


def declarations(text):
    masked = mask_literals(text)
    records = []
    for match in re.finditer(r'@Test\b', masked):
        cursor = match.end()
        while cursor < len(masked) and masked[cursor].isspace():
            cursor += 1
        attribute = ''
        if cursor < len(masked) and masked[cursor] == '(':
            end = closing(masked, cursor)
            attribute = masked[cursor + 1:end]
            cursor = end + 1
        function = re.search(r'\bfunc\s+(\w+)\s*\(', masked[cursor:])
        if not function:
            raise ValueError('Missing function after @Test')
        arguments = re.search(r'\barguments\s*:', attribute)
        cases = 1
        if arguments:
            cases = 1
            for collection in split_top_level(attribute[arguments.end():]):
                if collection.startswith('[') and collection.endswith(']'):
                    cases *= len(split_top_level(collection[1:-1]))
                else:
                    cases = None
                    break
        records.append({'name': function[1], 'line': text.count('\n', 0, match.start()) + 1,
                        'framework': 'Testing', 'parameterized': bool(arguments),
                        'static_cases': cases, 'benchmark': function[1].startswith('benchmark')})
    # XCTest discovery is name-based; these counts remain source declarations.
    for match in re.finditer(r'\bfunc\s+(test\w+)\s*\(', masked):
        records.append({'name': match[1], 'line': text.count('\n', 0, match.start()) + 1,
                        'framework': 'XCTest', 'parameterized': False,
                        'static_cases': 1, 'benchmark': False})
    return sorted(records, key=lambda item: item['line'])


def inventory(root):
    targets = {}
    for path in sorted((root / 'Tests').rglob('*.swift')):
        source = path.read_text()
        records = declarations(source)
        target = path.relative_to(root / 'Tests').parts[0]
        bucket = targets.setdefault(target, {'files': [], 'source_files': 0, 'lines': 0,
                                            'declared_tests': 0, 'parameterized_declarations': 0,
                                            'known_static_cases': 0, 'unresolved_parameterized_declarations': 0})
        bucket['source_files'] += 1
        bucket['lines'] += len(source.splitlines())
        bucket['declared_tests'] += len(records)
        bucket['parameterized_declarations'] += sum(item['parameterized'] for item in records)
        bucket['known_static_cases'] += sum(item['static_cases'] or 0 for item in records)
        bucket['unresolved_parameterized_declarations'] += sum(item['static_cases'] is None for item in records)
        bucket['files'].append({'path': str(path.relative_to(root)), 'lines': len(source.splitlines()),
                                'declarations': records})
    keys = ('source_files', 'lines', 'declared_tests', 'parameterized_declarations',
            'known_static_cases', 'unresolved_parameterized_declarations')
    return {'schema_version': 1, 'scope': 'All physical Tests directories, including opt-in targets',
            'limitations': 'Literal argument-array cardinalities only; dynamic collections, loops, skips, '
                            'conditional compilation and actual execution require runtime results.',
            'totals': {key: sum(value[key] for value in targets.values()) for key in keys},
            'targets': targets}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--json', action='store_true')
    args = parser.parse_args()
    result = inventory(REPO)
    if args.json:
        print(json.dumps(result, indent=2))
    else:
        print('Target: files / lines / declarations / parameterized / known static cases / unresolved')
        for name, target in result['targets'].items():
            print(name + ': ' + ' / '.join(str(target[key]) for key in result['totals']))
        print('TOTAL: ' + ' / '.join(str(value) for value in result['totals'].values()))
        print(result['limitations'])


if __name__ == '__main__':
    main()
