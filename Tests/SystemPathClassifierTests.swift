import Testing
@testable import DirWizCore

@Suite("SystemPathClassifier Tests")
struct SystemPathClassifierTests {

    @Test("Matches a real cryptex path under /System/Volumes/Preboot")
    func matchesCryptexPath() {
        #expect(SystemPathClassifier.isSystemManaged(
            "/System/Volumes/Preboot/9B8C33BA-.../cryptex1/current/os.dmg"
        ))
    }

    @Test("Matches /private/var/db/")
    func matchesPrivateVarDb() {
        #expect(SystemPathClassifier.isSystemManaged("/private/var/db/dyld/x"))
    }

    @Test("Matches /Library/Apple/")
    func matchesLibraryApple() {
        #expect(SystemPathClassifier.isSystemManaged("/Library/Apple/usr/share/rosetta/x"))
    }

    @Test("Matches /usr/")
    func matchesUsr() {
        #expect(SystemPathClassifier.isSystemManaged("/usr/lib/dyld"))
    }

    @Test("Does not match ordinary user paths")
    func doesNotMatchUserPaths() {
        #expect(!SystemPathClassifier.isSystemManaged("/Users/okan/x"))
    }

    @Test("Does not match /usr/local/ — the carved-out exception")
    func doesNotMatchUsrLocal() {
        #expect(!SystemPathClassifier.isSystemManaged("/usr/local/bin/x"))
    }

    @Test("Does not match a merely-textual prefix collision (/Systemx)")
    func respectsPathBoundary() {
        #expect(!SystemPathClassifier.isSystemManaged("/Systemx/evil"))
    }

    @Test("Does not match /Library/Application Support/")
    func doesNotMatchLibraryApplicationSupport() {
        #expect(!SystemPathClassifier.isSystemManaged("/Library/Application Support/x"))
    }

    @Test("Does not match /private/var/folders/ (user-clearable caches)")
    func doesNotMatchPrivateVarFolders() {
        #expect(!SystemPathClassifier.isSystemManaged("/private/var/folders/x"))
    }

    @Test("Group rule: all paths system-managed → true")
    func groupAllSystemIsTrue() {
        #expect(SystemPathClassifier.isSystemManagedGroup(paths: [
            "/System/Volumes/Preboot/cryptex1/current/os.dmg",
            "/System/Volumes/Preboot/cryptex1/proposed/os.dmg",
        ]))
    }

    @Test("Group rule: mixed system + user paths → false (stays actionable)")
    func groupMixedIsFalse() {
        #expect(!SystemPathClassifier.isSystemManagedGroup(paths: [
            "/System/Volumes/Preboot/cryptex1/current/os.dmg",
            "/Users/okan/Downloads/os.dmg",
        ]))
    }

    @Test("Group rule: all user paths → false")
    func groupAllUserIsFalse() {
        #expect(!SystemPathClassifier.isSystemManagedGroup(paths: [
            "/Users/okan/a.txt",
            "/Users/okan/b.txt",
        ]))
    }

    @Test("Group rule: empty paths → false")
    func groupEmptyIsFalse() {
        #expect(!SystemPathClassifier.isSystemManagedGroup(paths: []))
    }
}
