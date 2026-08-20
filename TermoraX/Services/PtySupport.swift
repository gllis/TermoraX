//
//  PtySupport.swift
//  TermoraX
//

import Darwin
import Foundation

enum PtySupport {
    private static var saved: termios?

    /// 8-bit clean link for ZMODEM only. Do not use for a normal shell session:
    /// `cfmakeraw` disables ECHO and ONLCR, so typed text disappears and LF no
    /// longer returns the cursor to column 0.
    static func beginBinary(_ master: Int32) {
        guard master >= 0 else { return }
        var term = termios()
        guard tcgetattr(master, &term) == 0 else { return }
        if saved == nil { saved = term }
        applyBinary(&term)
        _ = tcsetattr(master, TCSANOW, &term)
    }

    static func endBinary(_ master: Int32) {
        guard master >= 0, var saved else { return }
        _ = tcsetattr(master, TCSANOW, &saved)
        self.saved = nil
    }

    private static func applyBinary(_ term: inout termios) {
        term.c_iflag &= ~tcflag_t(ICRNL | IGNCR | INLCR | IXON | IXOFF)
        term.c_oflag &= ~tcflag_t(OPOST | ONLCR)
        term.c_lflag &= ~tcflag_t(ECHO | ECHOE | ECHOK | ECHONL | ICANON | IEXTEN)
        term.c_cflag |= tcflag_t(CS8)
    }
}
