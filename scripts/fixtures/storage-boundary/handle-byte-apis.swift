let reader = handle.read(upToCount:)
let writer = handle.write(contentsOf:)
let bytes = try handle.read(upToCount: 1024)
try handle.write(contentsOf: bytes)
