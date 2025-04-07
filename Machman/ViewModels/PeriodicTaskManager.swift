//
//  PreviewUpdateManager.swift
//  Machman
//
//  Created by Gustaf Franzen on 2025-04-07.
//

import Foundation

class PeriodicTaskManager <T> {
	private var isRunning = false
	private var thread: Thread?
	private let interval: TimeInterval
	private let task: () -> T
	private let update: (T) -> Void
	public var debug: Bool = false

	init(interval: TimeInterval, task: @escaping () -> T, update: @escaping (T) -> Void) {
		self.interval = interval
		self.task = task
		self.update = update
	}

	func start() {
		guard !isRunning else { return }
		isRunning = true

		if self.debug {
			print("Periodic task started\n")
		}

		thread = Thread { [weak self] in
			guard let self = self else { return }

			// Debug
			var time = Date().timeIntervalSince1970
			var first = true

			var nextExecutionDate = Date().addingTimeInterval(self.interval)
			var nextExecutionDateN = Date().addingTimeInterval(self.interval)

			while self.isRunning {

				if Thread.current.isCancelled {
					return
				}

				autoreleasepool {

					if self.debug {
						let tNow = Date().timeIntervalSince1970
						if first {
							print("update executed: error: (0)")
							first = false
						} else {
							print("update executed: error: (\(tNow - time - self.interval))")
						}
						time = tNow
					}

					let newValue = self.task()

					let updateGroup = DispatchGroup()
					updateGroup.enter()
					DispatchQueue.main.async {
						self.update(newValue)
						updateGroup.leave()
					}
					updateGroup.wait()
				}

				nextExecutionDateN = nextExecutionDate.addingTimeInterval(self.interval)
				Thread.sleep(until: nextExecutionDate)
				nextExecutionDate = nextExecutionDateN
			}
		}
		thread?.start()
	}

	func stop() {
		isRunning = false
		thread?.cancel()
		thread = nil
		if self.debug {
			print("Periodic task stopped\n")
		}
	}
}
