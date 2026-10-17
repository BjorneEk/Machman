//
//  SerialLogTrim.swift
//  MachmanCore
//
//  The capped serial log's trim (E67): the bridge hands its log to this off its own queue, and
//  it cuts the file to its tail one chunk at a time.
//

import Foundation

extension SerialPortBridge {
	// Cuts the file behind `fd` to its last `keeping` bytes in place: copies them forward
	// through one `chunk`-sized buffer, then truncates (E67). The same file, so an open reader
	// and the bridge's own handle keep it, and never more than one chunk in memory. The copy
	// never overtakes what it still has to read: every write lands below its source. `read`
	// is pread, a seam for tests.
	static func trimLog(
		fd: Int32, keeping: UInt64, chunk: Int = 1 << 20,
		read: (Int32, UnsafeMutableRawPointer, Int, off_t) -> Int = { pread($0, $1, $2, $3) }
	) throws {
		var info = stat()
		guard fstat(fd, &info) == 0 else { throw errnoError() }
		let size = off_t(info.st_size)
		guard size > keeping, keeping > 0 else { return }
		var buffer = [UInt8](repeating: 0, count: chunk)
		var from = size - off_t(keeping)
		var to: off_t = 0
		while from < size {
			let want = Int(min(off_t(chunk), size - from))
			let got = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress!, want, from) }
			if got < 0, errno == EINTR { continue }
			guard got > 0 else {
				if got < 0 { throw errnoError() }
				break   // the file ended early: keep what was copied
			}
			var written = 0
			while written < got {
				let n = buffer.withUnsafeBytes {
					pwrite(fd, $0.baseAddress! + written, got - written, to + off_t(written))
				}
				if n < 0, errno == EINTR { continue }
				guard n > 0 else { throw errnoError() }
				written += n
			}
			from += off_t(got)
			to += off_t(got)
		}
		guard ftruncate(fd, to) == 0 else { throw errnoError() }
	}

	private static func errnoError() -> POSIXError {
		POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
	}
}
