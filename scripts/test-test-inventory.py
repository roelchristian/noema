#!/usr/bin/env python3
"""Focused scanner tests: parameter cardinality and misleading source literals."""
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('inventory', Path(__file__).with_name('test-inventory.py'))
inventory = importlib.util.module_from_spec(spec)
spec.loader.exec_module(inventory)


class InventoryTests(unittest.TestCase):
    def test_comments_raw_strings_and_multiline_strings_are_not_declarations(self):
        source = '// @Test func fake() {}\n/* nested /* @Test */ comment */\n'
        source += 'let s = #"@Test func hidden() {}"#\nlet t = """@Test func hidden2() {}"""\n'
        source += '@Test func real() {}\n'
        self.assertEqual([item['name'] for item in inventory.declarations(source)], ['real'])

    def test_literal_arrays_count_strings_nested_values_and_cartesian_products(self):
        source = '@Test(arguments: ["a,b", #"x,y"#, """p,q"""], [false, true]) func matrix() {}'
        self.assertEqual(inventory.declarations(source)[0]['static_cases'], 6)
        source = '@Test(arguments: [(1, 2), (3, 4)]) func tuples() {}'
        self.assertEqual(inventory.declarations(source)[0]['static_cases'], 2)

    def test_dynamic_cases_are_unknown_instead_of_one(self):
        item = inventory.declarations('@Test(arguments: Foo.allCases, [true, false]) func dynamic() {}')[0]
        self.assertTrue(item['parameterized'])
        self.assertIsNone(item['static_cases'])

    def test_body_loops_and_xctest_are_separate_declarations(self):
        source = '@Test func loops() { for i in 0..<64 { check(i) } }\nfunc testLegacy() {}'
        items = inventory.declarations(source)
        self.assertEqual(len(items), 2)
        self.assertEqual([item['static_cases'] for item in items], [1, 1])
        self.assertEqual(items[1]['framework'], 'XCTest')


if __name__ == '__main__':
    unittest.main()
