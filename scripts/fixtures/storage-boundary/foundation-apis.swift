let manager = FileManager.default
try manager.createDirectory(at: canonicalURL, withIntermediateDirectories: true)
let bytes = manager.contents(atPath: canonicalURL.path)
try manager.replaceItemAt(canonicalURL, withItemAt: replacementURL)
try manager.linkItem(at: canonicalURL, to: linkedURL)
try manager.createSymbolicLink(at: canonicalURL, withDestinationURL: linkedURL)
let handle = try FileHandle.init(forReadingFrom: canonicalURL)
let rest = try handle.readToEnd()
try handle.truncate(atOffset: 0)
