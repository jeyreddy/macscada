// MARK: - ModbusSerialPort.swift
//
// POSIX/termios serial port wrapper for Modbus RTU and ASCII physical transport.
//
// ── Port Setup ────────────────────────────────────────────────────────────────
//   open(): opens device with O_RDWR | O_NOCTTY | O_NONBLOCK
//   Configures via tcsetattr():
//     baud:     cfsetispeed / cfsetospeed with B9600..B115200 constants
//     dataBits: CS7 or CS8 bits in c_cflag
//     parity:   PARENB (even/odd), PARODD (odd only); none = no PARENB
//     stopBits: CSTOPB (2 stop bits) or unset (1 stop bit)
//     raw mode: cfmakeraw() disables all line-discipline processing
//
// ── Read Loop ─────────────────────────────────────────────────────────────────
//   DispatchSourceRead on nwQueue watches fd for readable data.
//   Chunks are accumulated into receiveBuffer.
//   onReceive(@MainActor callback) is called whenever new data arrives.
//   ModbusDriver is responsible for framing: RTU collects until inter-frame
//   silence > interFrameDelay; ASCII collects until CR+LF line terminator.
//
// ── Write ─────────────────────────────────────────────────────────────────────
//   send(_ data: Data) writes synchronously via Darwin.write() on callers' queue.
//   RTU: append CRC-16/ARC to PDU before sending.
//   ASCII: encode as ":HH...HH<LRC>\r\n" where LRC = two's complement of sum.
//
// ── Inter-Frame Delay ─────────────────────────────────────────────────────────
//   interFrameDelay (from ModbusSerialParams) = max(3.5 * charTime, 1.75 ms).
//   ModbusDriver inserts this delay between consecutive requests via Task.sleep().
//   Required by Modbus RTU spec §2.5.1.1 for reliable frame delimitation.
//
// ── Models ────────────────────────────────────────────────────────────────────
//   ModbusSerialParity: none/even/odd (default: none)
//   ModbusSerialParams: path, baud, dataBits, parity, stopBits + interFrameDelay

import Foundation
import Darwin

// MARK: - ModbusSerialParity

enum ModbusSerialParity: String, Codable, CaseIterable {
    case none = "N"
    case even = "E"
    case odd  = "O"

    var displayName: String {
        switch self {
        case .none: return "None"
        case .even: return "Even"
        case .odd:  return "Odd"
        }
    }
}

// MARK: - ModbusSerialParams

/// Physical serial port parameters for Modbus RTU / ASCII connections.
struct ModbusSerialParams {
    var path:     String                = ""
    var baud:     Int                   = 9600
    var dataBits: Int                   = 8     // 7 for ASCII-Modbus, 8 for RTU
    var parity:   ModbusSerialParity    = .none  // Even common for ASCII-Modbus
    var stopBits: Int                   = 1

    // MARK: Derived timing

    /// Minimum silence between RTU frames (ISA: 3.5 character times, ≥ 1.75 ms).
    ///
    /// Character time at 8N1 = 10 bits; at 7E1 = 10 bits; worst case 11 bits.
    /// We conservatively use 11 bits/char so all configurations are covered.
    var interFrameDelay: TimeInterval {
        let charTime = 11.0 / Double(baud)   // seconds per character (11 bits/char)
        return max(3.5 * charTime, 0.00175)  // minimum 1.75 ms per spec §2.5.1.1
    }

    // MARK: Parse from DriverConfig.parameters

    /// Parses optional keys: baud, databits, parity, stopbits.
    init(path: String, parameters: [String: String]) {
        self.path     = path
        self.baud     = Int(parameters["baud"]     ?? "9600") ?? 9600
        self.dataBits = Int(parameters["databits"] ?? "8")    ?? 8
        self.parity   = ModbusSerialParity(rawValue: (parameters["parity"] ?? "N").uppercased())
                        ?? .none
        self.stopBits = Int(parameters["stopbits"] ?? "1")    ?? 1
    }
}

// MARK: - ModbusSerialPort

/// POSIX/termios serial port for Modbus RTU and ASCII.
///
/// - Opens the device with `O_RDWR | O_NOCTTY | O_NONBLOCK`.
/// - Configures baud rate, data bits, parity, and stop bits via `termios`.
/// - Runs a `DispatchSourceRead` read loop; delivers chunks to `onReceive` on the main actor.
/// - Thread-safety: `open`, `close`, and `write` must be called from the main actor.
///   The read event handler dispatches back to the main actor before invoking `onReceive`.
@MainActor
final class ModbusSerialPort {

    // Read callbacks (called on MainActor)
    var onReceive: ((Data) -> Void)?
    var onError:   (() -> Void)?

    var isOpen: Bool { fd >= 0 }

    private var fd:     Int32              = -1
    private var source: DispatchSourceRead?
    private let ioQueue = DispatchQueue(label: "com.industrialhmi.modbus.serial", qos: .utility)

    // MARK: - Open / Close

    func open(params: ModbusSerialParams) throws {
        guard !isOpen else { return }

        let rawFd = Darwin.open(params.path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard rawFd >= 0 else {
            throw DriverError.connectionFailed(
                "Cannot open \(params.path): \(String(cString: strerror(errno)))")
        }
        fd = rawFd

        do {
            try configure(params: params)
        } catch {
            Darwin.close(rawFd)
            fd = -1
            throw error
        }

        startReadSource(fd: rawFd)
        Logger.shared.info("ModbusSerial: opened \(params.path) @ \(params.baud) \(params.dataBits)\(params.parity.rawValue)\(params.stopBits)")
    }

    /// Closes the port and cancels the read source.
    /// The underlying file descriptor is closed asynchronously by the cancel handler.
    func close() {
        guard isOpen else { return }
        fd = -1             // stop new writes immediately
        source?.cancel()    // cancel handler closes the captured fd
        source = nil
    }

    // MARK: - Write

    /// Write raw bytes to the serial port.  Fire-and-forget; errors are logged.
    func write(_ data: Data) {
        guard fd >= 0 else { return }
        let capturedFd = fd
        data.withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            let written = Darwin.write(capturedFd, base, data.count)
            if written < 0 {
                Logger.shared.error("ModbusSerial write error: \(String(cString: strerror(errno)))")
            }
        }
    }

    // MARK: - termios Configuration

    private func configure(params: ModbusSerialParams) throws {
        var tty = termios()
        tcgetattr(fd, &tty)

        // ── Baud rate ──────────────────────────────────────────────────────────
        let speed = speedT(params.baud)
        cfsetispeed(&tty, speed)
        cfsetospeed(&tty, speed)

        // ── Data bits ─────────────────────────────────────────────────────────
        tty.c_cflag &= ~UInt(CSIZE)
        tty.c_cflag |= (params.dataBits == 7) ? UInt(CS7) : UInt(CS8)

        // ── Parity ────────────────────────────────────────────────────────────
        switch params.parity {
        case .none:
            tty.c_cflag &= ~UInt(PARENB)
            tty.c_iflag &= ~UInt(INPCK)
        case .even:
            tty.c_cflag |=  UInt(PARENB)
            tty.c_cflag &= ~UInt(PARODD)
            tty.c_iflag |=  UInt(INPCK)
        case .odd:
            tty.c_cflag |= UInt(PARENB | PARODD)
            tty.c_iflag |= UInt(INPCK)
        }

        // ── Stop bits ─────────────────────────────────────────────────────────
        if params.stopBits == 2 {
            tty.c_cflag |=  UInt(CSTOPB)
        } else {
            tty.c_cflag &= ~UInt(CSTOPB)
        }

        // ── Flow control / receiver ───────────────────────────────────────────
        tty.c_cflag &= ~UInt(CRTSCTS)
        tty.c_cflag |=  UInt(CLOCAL | CREAD)

        // ── Raw input (no line discipline) ────────────────────────────────────
        tty.c_lflag &= ~UInt(ICANON | ECHO | ECHOE | ISIG)
        tty.c_iflag &= ~UInt(IXON | IXOFF | IXANY | ICRNL | INLCR | IGNCR)
        tty.c_oflag &= ~UInt(OPOST)

        // ── VMIN=0 / VTIME=0: non-blocking read (O_NONBLOCK already set) ─────
        withUnsafeMutableBytes(of: &tty.c_cc) { buf in
            buf[Int(VMIN)]  = 0
            buf[Int(VTIME)] = 0
        }

        guard tcsetattr(fd, TCSANOW, &tty) == 0 else {
            throw DriverError.connectionFailed(
                "tcsetattr failed for \(params.path): \(String(cString: strerror(errno)))")
        }

        tcflush(fd, TCIOFLUSH)   // discard stale bytes in OS kernel buffers
    }

    private func speedT(_ baud: Int) -> speed_t {
        switch baud {
        case 1200:   return speed_t(B1200)
        case 2400:   return speed_t(B2400)
        case 4800:   return speed_t(B4800)
        case 9600:   return speed_t(B9600)
        case 19200:  return speed_t(B19200)
        case 38400:  return speed_t(B38400)
        case 57600:  return speed_t(B57600)
        case 115200: return speed_t(B115200)
        default:
            Logger.shared.warning("ModbusSerial: unsupported baud \(baud), using 9600")
            return speed_t(B9600)
        }
    }

    // MARK: - DispatchSource Read Loop

    private func startReadSource(fd capturedFd: Int32) {
        let src = DispatchSource.makeReadSource(fileDescriptor: capturedFd, queue: ioQueue)

        src.setEventHandler { [weak self] in
            var buf = [UInt8](repeating: 0, count: 512)
            let n = Darwin.read(capturedFd, &buf, buf.count)
            if n > 0 {
                let data = Data(buf[0..<n])
                DispatchQueue.main.async { self?.onReceive?(data) }
            } else if n < 0 && errno != EAGAIN && errno != EINTR {
                DispatchQueue.main.async { self?.onError?() }
            }
        }

        src.setCancelHandler {
            Darwin.close(capturedFd)
        }

        src.resume()
        source = src
    }
}

// MARK: - Modbus Error Checking Helpers (used by ModbusDriver)

/// Compute the Modbus RTU CRC-16 (polynomial 0xA001, reflected, initial value 0xFFFF).
/// Transmitted little-endian: `[crc & 0xFF, crc >> 8]`.
func modbusCRC16(_ data: Data) -> UInt16 {
    var crc: UInt16 = 0xFFFF
    for byte in data {
        crc ^= UInt16(byte)
        for _ in 0..<8 {
            crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xA001 : crc >> 1
        }
    }
    return crc
}

/// Compute the Modbus ASCII LRC (two's complement of the byte sum).
/// Input is the binary bytes whose ASCII hex representation sits between `:` and the LRC field.
func modbusLRC(_ bytes: [UInt8]) -> UInt8 {
    let sum = bytes.reduce(UInt8(0), &+)   // 8-bit wrapping sum
    return (~sum) &+ 1                      // two's complement negation
}
