let manager = FileManager.default
try manager.setAttributes([.posixPermissions: 0o777], ofItemAtPath: canonicalURL.path)
