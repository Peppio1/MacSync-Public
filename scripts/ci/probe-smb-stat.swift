// Test-only local smbfs stat, called with one disposable synthetic path.
// Print only numeric file metadata, never paths or credentials.
import Darwin

guard CommandLine.arguments.count == 2 else { Darwin.exit(2) }
var info = stat()
guard CommandLine.arguments[1].withCString({ Darwin.lstat($0, &info) }) == 0 else {
    Darwin.exit(1)
}
let billion: Int64 = 1_000_000_000
let birth = Int64(info.st_birthtimespec.tv_sec) * billion + Int64(info.st_birthtimespec.tv_nsec)
let modified = Int64(info.st_mtimespec.tv_sec) * billion + Int64(info.st_mtimespec.tv_nsec)
print("\(UInt64(info.st_ino)) \(birth) \(modified) \(Int64(info.st_size))")
