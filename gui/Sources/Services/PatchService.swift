import Foundation

public final class PatchService {
    public static let shared = PatchService()
    
    private init() {}
    
    public func checkPatchStatuses(nxnativePath: String) -> [EnginePatchItem] {
        let root = URL(fileURLWithPath: nxnativePath)
        let fm = FileManager.default
        
        return EnginePatchRegistry.patches.map { def in
            let fileURL = root.appendingPathComponent(def.relativePath)
            guard fm.fileExists(atPath: fileURL.path),
                  let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
                return EnginePatchItem(id: def.id, name: def.name, summary: def.summary, relativePath: def.relativePath, isApplied: false)
            }
            let applied = content.contains(def.checkToken)
            return EnginePatchItem(id: def.id, name: def.name, summary: def.summary, relativePath: def.relativePath, isApplied: applied)
        }
    }
    
    /// A failed `git stash pop` (or merge) leaves files unmerged with `<<<<<<<` markers, which breaks
    /// `build_ipa_from_nsp.py` with a SyntaxError. Restore each such file from HEAD (upstream);
    /// the compatibility patches below are re-applied on top. Returns the repaired paths.
    @discardableResult
    public func repairUnmergedFiles(nxnativePath: String) -> [String] {
        func git(_ args: [String]) -> String {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-C", nxnativePath] + args
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = Pipe()
            guard (try? p.run()) != nil else { return "" }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return String(data: data, encoding: .utf8) ?? ""
        }
        let files = git(["diff", "--name-only", "--diff-filter=U"])
            .split(separator: "\n").map(String.init)
        for f in files {
            _ = git(["checkout", "HEAD", "--", f])
            _ = git(["reset", "-q", "HEAD", "--", f])
        }
        return files
    }
    
    @discardableResult
    public func applyPatchesIfNeeded(
        nxnativePath: String,
        logger: ((String, Bool) -> Void)? = nil
    ) -> (applied: Int, skipped: Int, errors: [String]) {
        let root = URL(fileURLWithPath: nxnativePath)
        let fm = FileManager.default
        
        var appliedCount = 0
        var skippedCount = 0
        var errorMessages: [String] = []
        
        for f in repairUnmergedFiles(nxnativePath: nxnativePath) {
            logger?("[Repo] Restored \(f) from upstream: it was left with unresolved merge conflicts", true)
        }
        
        for def in EnginePatchRegistry.patches {
            let fileURL = root.appendingPathComponent(def.relativePath)
            guard fm.fileExists(atPath: fileURL.path) else {
                let msg = "Skipped \(def.name): file not found at \(def.relativePath)"
                logger?(msg, false)
                continue
            }
            
            guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
                let msg = "Error reading \(def.relativePath)"
                errorMessages.append(msg)
                logger?(msg, false)
                continue
            }
            
            // If already contains token, it's either merged upstream or previously applied
            if content.contains(def.checkToken) {
                // Self-heal: if global_60fps_speed_sync was previously applied without the weak declaration of dm_fps_has_engine_lock, inject it now
                if def.id == "global_60fps_speed_sync" && !content.contains("int dm_fps_has_engine_lock(void)") {
                    let weakDecl = "__attribute__((weak)) int dm_fps_has_engine_lock(void) { return 0; }\n\nstatic int speed_sync_on(void)"
                    if content.contains("static int speed_sync_on(void)") {
                        let healed = content.replacingOccurrences(of: "static int speed_sync_on(void)", with: weakDecl)
                        try? healed.write(to: fileURL, atomically: true, encoding: .utf8)
                        appliedCount += 1
                        logger?("[Patch] Repaired missing weak declaration in \(def.relativePath)", true)
                        continue
                    }
                }
                skippedCount += 1
                logger?("[Patch] \(def.name): Already applied or upstream merged.", false)
                continue
            }
            
            // Perform non-destructive transformation
            guard let modified = def.applyTransform(content) else {
                let msg = "[Patch] Warning: Pattern anchor not found for \(def.name) in \(def.relativePath)"
                errorMessages.append(msg)
                logger?(msg, false)
                continue
            }
            
            do {
                try modified.write(to: fileURL, atomically: true, encoding: .utf8)
                appliedCount += 1
                logger?("[Patch] Successfully applied: \(def.name)", true)
            } catch {
                let msg = "[Patch] Failed to write \(def.relativePath): \(error.localizedDescription)"
                errorMessages.append(msg)
                logger?(msg, false)
            }
        }
        
        return (appliedCount, skippedCount, errorMessages)
    }
}
