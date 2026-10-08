import Foundation

/// Moves one desktop icon smoothly by keeping a small Finder script alive and streaming positions to it.
/// The script always applies the newest position it has received, so it keeps up at whatever rate Finder allows.
final class IconMover {
    private var process: Process?
    private var input: FileHandle?
    private let queue = DispatchQueue(label: "duck.iconmover")
    private(set) var failed = false

    private static let script = """
    ObjC.import('Foundation');
    function run(argv) {
      const item = Application('Finder').desktop.items.byName(argv[0]);
      item.desktopPosition();
      const stdin = $.NSFileHandle.fileHandleWithStandardInput;
      while (true) {
        const d = stdin.availableData;
        if (d.length == 0) break;
        const lines = $.NSString.alloc.initWithDataEncoding(d, 4).js.trim().split('\\n');
        const p = lines[lines.length - 1].split(',').map(Number);
        if (p.length == 2 && !isNaN(p[0]) && !isNaN(p[1])) item.desktopPosition = {x: Math.round(p[0]), y: Math.round(p[1])};
      }
    }
    """

    func begin(iconName: String) {
        end()
        failed = false
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-l", "JavaScript", "-e", IconMover.script, iconName]
        let pipe = Pipe()
        p.standardInput = pipe
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { [weak self] proc in
            if proc.terminationStatus != 0 { DispatchQueue.main.async { self?.failed = true } }
        }
        do { try p.run() } catch { failed = true; return }
        process = p
        input = pipe.fileHandleForWriting
    }

    /// Position in Finder coordinates (top-left origin).
    func move(to finderPoint: CGPoint) {
        guard let input else { return }
        let line = "\(Int(finderPoint.x.rounded())),\(Int(finderPoint.y.rounded()))\n"
        queue.async { try? input.write(contentsOf: Data(line.utf8)) }
    }

    func end() {
        guard let input else { return }
        self.input = nil
        process = nil
        queue.async { try? input.close() }
    }
}
