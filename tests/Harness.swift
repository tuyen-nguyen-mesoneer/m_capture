import Foundation
import ObjectiveC

/// Base class for a group of checks. A suite is found by the ObjC runtime, the way XCTest
/// finds its cases, so adding one is adding a file: subclass this directly and mark each
/// check `@objc func check…()`. Swift 5 does not expose methods to the runtime on its own,
/// so a suite with no `@objc` checks is reported as a failure rather than silently passing.
///
/// Failures are counted, never trapped: `assert` / `precondition` are compiled out under
/// `-O`, and a trap would stop the run at the first broken check instead of naming all of them.
class CheckSuite: NSObject {
    fileprivate(set) var failures: [Failure] = []

    struct Failure {
        let message: String
        let file: String
        let line: UInt
    }

    required override init() { super.init() }

    /// Records a failure at the call site when `condition` is false.
    func expect(_ condition: Bool, _ message: @autoclosure () -> String,
                file: StaticString = #filePath, line: UInt = #line) {
        guard !condition else { return }
        failures.append(Failure(message: message(), file: CheckRunner.displayPath("\(file)"), line: line))
    }
}

/// Discovers every direct `CheckSuite` subclass, runs each `check…` method on a fresh
/// instance, prints a summary and returns the process exit status (0 only if all passed).
enum CheckRunner {
    static func run() -> Int32 {
        let suites = discoverSuites()
        guard !suites.isEmpty else {
            print("FAIL  no CheckSuite subclasses found")
            return 1
        }

        var passed = 0
        var failed = 0
        for suite in suites {
            let name = NSStringFromClass(suite)
            let checks = checkSelectors(of: suite)
            if checks.isEmpty {
                print("FAIL  \(name): no @objc check… methods found")
                failed += 1
                continue
            }
            for selector in checks {
                let instance = suite.init()
                typealias CheckIMP = @convention(c) (AnyObject, Selector) -> Void
                guard let method = class_getInstanceMethod(suite, selector) else { continue }
                let call = unsafeBitCast(method_getImplementation(method), to: CheckIMP.self)
                call(instance, selector)

                let label = "\(name).\(NSStringFromSelector(selector))"
                if instance.failures.isEmpty {
                    print("ok    \(label)")
                    passed += 1
                } else {
                    print("FAIL  \(label)")
                    for f in instance.failures {
                        print("      \(f.file):\(f.line): \(f.message)")
                        if ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true" {
                            print("::error file=\(f.file),line=\(f.line)::\(label): \(f.message)")
                        }
                    }
                    failed += 1
                }
            }
        }

        print("\n\(passed) passed, \(failed) failed")
        return failed == 0 ? 0 : 1
    }

    /// Strips the working directory so failures read `tests/Foo.swift:12`.
    static func displayPath(_ path: String) -> String {
        let cwd = FileManager.default.currentDirectoryPath + "/"
        return path.hasPrefix(cwd) ? String(path.dropFirst(cwd.count)) : path
    }

    private static func discoverSuites() -> [CheckSuite.Type] {
        let count = objc_getClassList(nil, 0)
        guard count > 0 else { return [] }
        let buffer = UnsafeMutablePointer<AnyClass>.allocate(capacity: Int(count))
        defer { buffer.deallocate() }
        let filled = objc_getClassList(AutoreleasingUnsafeMutablePointer(buffer), count)

        let base: AnyClass = CheckSuite.self
        var suites: [CheckSuite.Type] = []
        for i in 0..<Int(min(count, filled)) {
            let cls: AnyClass = buffer[i]
            guard let superclass = class_getSuperclass(cls),
                  ObjectIdentifier(superclass) == ObjectIdentifier(base),
                  let suite = cls as? CheckSuite.Type else { continue }
            suites.append(suite)
        }
        return suites.sorted { NSStringFromClass($0) < NSStringFromClass($1) }
    }

    private static func checkSelectors(of cls: AnyClass) -> [Selector] {
        var count: UInt32 = 0
        guard let methods = class_copyMethodList(cls, &count) else { return [] }
        defer { free(methods) }
        return (0..<Int(count))
            .map { method_getName(methods[$0]) }
            .filter { NSStringFromSelector($0).hasPrefix("check") && !NSStringFromSelector($0).contains(":") }
            .sorted { NSStringFromSelector($0) < NSStringFromSelector($1) }
    }
}
