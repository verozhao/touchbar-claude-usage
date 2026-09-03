import Foundation

/// ~/.claude/touchbar/config.json (shared with the hook script, which reads wait_seconds).
struct Config {
    var waitSeconds: Int = 60          // how long the hook waits for a Touch Bar tap
    var refreshSeconds: Double = 180   // usage API poll interval (the endpoint rate-limits below ~180 s)
    var keepControlStrip: Bool = true  // leave the macOS Control Strip (brightness/volume) visible
    var autoPresent: Bool = true       // re-present the bar when you switch apps (unless you closed it)
    var sound: Bool = false            // play a sound when a permission prompt arrives
    var showTray: Bool = true          // small "C 9%" button in the Control Strip
    var menuBarDetails: Bool = false   // show usage numbers in the menu bar title (otherwise just "C")
    var showMenuBar: Bool = true       // the "C" menu bar item at all

    static func load(from url: URL) -> Config {
        var c = Config()
        guard let data = try? Data(contentsOf: url),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return c }
        if let v = o["wait_seconds"] as? Int { c.waitSeconds = v }
        if let v = o["refresh_seconds"] as? Double { c.refreshSeconds = max(120, v) }
        if let v = o["keep_control_strip"] as? Bool { c.keepControlStrip = v }
        if let v = o["auto_present"] as? Bool { c.autoPresent = v }
        if let v = o["sound"] as? Bool { c.sound = v }
        if let v = o["show_tray"] as? Bool { c.showTray = v }
        if let v = o["menu_bar_details"] as? Bool { c.menuBarDetails = v }
        if let v = o["show_menu_bar"] as? Bool { c.showMenuBar = v }
        return c
    }

    func save(to url: URL) {
        let o: [String: Any] = ["wait_seconds": waitSeconds, "refresh_seconds": refreshSeconds,
                                "keep_control_strip": keepControlStrip, "auto_present": autoPresent,
                                "sound": sound, "show_tray": showTray, "menu_bar_details": menuBarDetails, "show_menu_bar": showMenuBar]
        if let d = try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: url)
        }
    }
}
