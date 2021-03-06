import LlamaKit

/// A push-driven stream that sends Events over time, parameterized by the type
/// of values being sent (`T`) and the type of error that can occur (`E`). If no
/// errors should be possible, NoError can be specified for `E`.
///
/// An observer of a Signal will see the exact same sequence of events as all
/// other observers. In other words, events will be sent to all observers at the
/// same time.
///
/// Signals are generally used to represent event streams that are already “in
/// progress,” like notifications, user input, etc. To represent streams that
/// must first be _started_, see the SignalProducer type.
///
/// Signals do not need to be retained. A Signal will be automatically kept
/// alive until the event stream has terminated.
public final class Signal<T, E: ErrorType> {
	public typealias Observer = SinkOf<Event<T, E>>

	private let lock = NSRecursiveLock()
	private var observers: Bag<Observer>? = Bag()

	/// Initializes a Signal that will immediately invoke the given generator,
	/// then forward events sent to the given observer.
	///
	/// The Signal will remain alive until a terminating event is sent to the
	/// observer, at which point the disposable returned from the closure will
	/// be disposed as well.
	public init(_ generator: Observer -> Disposable?) {
		lock.name = "org.reactivecocoa.ReactiveCocoa.Signal"

		let generatorDisposable = SerialDisposable()
		let sink = Observer { event in
			self.lock.lock()

			if let observers = self.observers {
				if event.isTerminating {
					// Disallow any further events (e.g., any triggered
					// recursively).
					self.observers = nil
				}

				for sink in observers {
					sink.put(event)
				}

				if event.isTerminating {
					// Dispose only after notifying observers, so disposal logic
					// is consistently the last thing to run.
					generatorDisposable.dispose()
				}
			}

			self.lock.unlock()
		}

		generatorDisposable.innerDisposable = generator(sink)
	}

	/// A Signal that never sends any events to its observers.
	public class var never: Signal {
		return self { _ in nil }
	}

	/// Creates a Signal that will be controlled by sending events to the given
	/// observer (sink).
	///
	/// The Signal will remain alive until a terminating event is sent to the
	/// observer.
	public class func pipe() -> (Signal, Observer) {
		var sink: Observer!
		let signal = self { innerSink in
			sink = innerSink
			return nil
		}

		return (signal, sink)
	}

	/// Observes the Signal by sending any future events to the given sink. If
	/// the Signal has already terminated, the sink will immediately receive an
	/// `Interrupted` event.
	///
	/// Returns a Disposable which can be used to disconnect the sink. Disposing
	/// of the Disposable will have no effect on the Signal itself.
	public func observe<S: SinkType where S.Element == Event<T, E>>(observer: S) -> Disposable? {
		let sink = Observer(observer)

		lock.lock()
		let token = self.observers?.insert(sink)
		lock.unlock()

		if let token = token {
			return ActionDisposable {
				self.lock.lock()
				self.observers?.removeValueForToken(token)
				self.lock.unlock()
			}
		} else {
			sink.put(.Interrupted)
			return nil
		}
	}

	/// Observes the Signal by invoking the given callbacks when events are
	/// received. If the Signal has already terminated, the `interrupted`
	/// callback will be invoked immediately.
	///
	/// Returns a Disposable which can be used to stop the invocation of the
	/// callbacks. Disposing of the Disposable will have no effect on the Signal
	/// itself.
	public func observe(next: (T -> ())? = nil, error: (E -> ())? = nil, completed: (() -> ())? = nil, interrupted: (() -> ())? = nil) -> Disposable? {
		return observe(Event.sink(next: next, error: error, completed: completed, interrupted: interrupted))
	}
}

infix operator |> {
	associativity left

	// Bind tighter than assignment, but looser than everything else.
	precedence 95
}

/// Applies a Signal operator to a Signal.
///
/// Example:
///
/// 	intSignal
/// 	|> filter { num in num % 2 == 0 }
/// 	|> map(toString)
/// 	|> observe(next: { string in println(string) })
public func |> <T, E, X>(signal: Signal<T, E>, transform: Signal<T, E> -> X) -> X {
	return transform(signal)
}

/// Maps each value in the signal to a new value.
public func map<T, U, E>(transform: T -> U)(signal: Signal<T, E>) -> Signal<U, E> {
	return Signal { observer in
		return signal.observe(Signal.Observer { event in
			observer.put(event.map(transform))
		})
	}
}

/// Maps errors in the signal to a new error.
public func mapError<T, E, F>(transform: E -> F)(signal: Signal<T, E>) -> Signal<T, F> {
	return Signal { observer in
		return signal.observe(Signal.Observer { event in
			switch event {
			case let .Next(value):
				sendNext(observer, value.unbox)
			case let .Error(error):
				sendError(observer, transform(error.unbox))
			case .Completed:
				sendCompleted(observer)
			case .Interrupted:
				sendInterrupted(observer)
			}
		})
	}
}

/// Preserves only the values of the signal that pass the given predicate.
public func filter<T, E>(predicate: T -> Bool)(signal: Signal<T, E>) -> Signal<T, E> {
	return Signal { observer in
		return signal.observe(Signal.Observer { event in
			switch event {
			case let .Next(value):
				if predicate(value.unbox) {
					sendNext(observer, value.unbox)
				}

			default:
				observer.put(event)
			}
		})
	}
}

/// Unwraps non-`nil` values from `signal` and forwards them on the returned
/// signal, `nil` values are dropped.
public func ignoreNil<T, E>(signal: Signal<T?, E>) -> Signal<T, E> {
	return signal |> filter { $0 != nil } |> map { $0! }
}

/// Returns a signal that will yield the first `count` values from the
/// input signal.
public func take<T, E>(count: Int)(signal: Signal<T, E>) -> Signal<T, E> {
	precondition(count >= 0)

	return Signal { observer in
		if count == 0 {
			sendCompleted(observer)
			return nil
		}

		var taken = 0

		return signal.observe(Signal.Observer { event in
			switch event {
			case let .Next(value):
				if taken < count {
					taken++
					sendNext(observer, value.unbox)
				}

				if taken == count {
					sendCompleted(observer)
				}

			default:
				observer.put(event)
			}
		})
	}
}

/// Returns a signal that will yield an array of values when `signal` completes.
public func collect<T, E>(signal: Signal<T, E>) -> Signal<[T], E> {
	return signal |> reduce([]) { $0 + [ $1 ] }
}

/// Forwards all events onto the given scheduler, instead of whichever
/// scheduler they originally arrived upon.
public func observeOn<T, E>(scheduler: SchedulerType) -> (Signal<T, E>) -> Signal<T, E> {
	return { signal in
		return Signal { observer in
			return signal.observe(SinkOf { event in
				scheduler.schedule {
					observer.put(event)
				}

				return
			})
		}
	}
}

private class CombineLatestState<T> {
	var latestValue: T?
	var completed = false
}

private func observeWithStates<T, U, E>(signalState: CombineLatestState<T>, otherState: CombineLatestState<U>, lock: NSRecursiveLock, onBothNext: () -> (), onError: E -> (), onBothCompleted: () -> (), onInterrupted: () -> ())(signal: Signal<T, E>) -> Disposable? {
	return signal.observe(next: { value in
		lock.lock()

		signalState.latestValue = value
		if otherState.latestValue != nil {
			onBothNext()
		}

		lock.unlock()
	}, error: onError, completed: {
		lock.lock()

		signalState.completed = true
		if otherState.completed {
			onBothCompleted()
		}

		lock.unlock()
	}, interrupted: onInterrupted)
}

/// Combines the latest value of the receiver with the latest value from
/// the given signal.
///
/// The returned signal will not send a value until both inputs have sent
/// at least one value each. If either signal is interrupted, the returned signal
/// will also be interrupted.
public func combineLatestWith<T, U, E>(otherSignal: Signal<U, E>)(signal: Signal<T, E>) -> Signal<(T, U), E> {
	return Signal { observer in
		let lock = NSRecursiveLock()
		lock.name = "org.reactivecocoa.ReactiveCocoa.combineLatestWith"

		let signalState = CombineLatestState<T>()
		let otherState = CombineLatestState<U>()

		let onBothNext = { () -> () in
			let combined = (signalState.latestValue!, otherState.latestValue!)
			sendNext(observer, combined)
		}

		let onError = { sendError(observer, $0) }
		let onBothCompleted = { sendCompleted(observer) }
		let onInterrupted = { sendInterrupted(observer) }

		let signalDisposable = signal |> observeWithStates(signalState, otherState, lock, onBothNext, onError, onBothCompleted, onInterrupted)
		let otherDisposable = otherSignal |> observeWithStates(otherState, signalState, lock, onBothNext, onError, onBothCompleted, onInterrupted)

		return CompositeDisposable(ignoreNil([ signalDisposable, otherDisposable ]))
	}
}

/// Delays `Next` and `Completed` events by the given interval, forwarding
/// them on the given scheduler.
///
/// `Error` and `Interrupted` events are always scheduled immediately.
public func delay<T, E>(interval: NSTimeInterval, onScheduler scheduler: DateSchedulerType) -> Signal<T, E> -> Signal<T, E> {
	precondition(interval >= 0)

	return { signal in
		return Signal { observer in
			return signal.observe(SinkOf { event in
				switch event {
				case .Error, .Interrupted:
					scheduler.schedule {
						observer.put(event)
					}

				default:
					let date = scheduler.currentDate.dateByAddingTimeInterval(interval)
					scheduler.scheduleAfter(date) {
						observer.put(event)
					}
				}
			})
		}
	}
}

/// Returns a signal that will skip the first `count` values, then forward
/// everything afterward.
public func skip<T, E>(count: Int)(signal: Signal<T, E>) -> Signal<T, E> {
	precondition(count >= 0)

	if (count == 0) {
		return signal
	}

	return Signal { observer in
		var skipped = 0

		return signal.observe(SinkOf { event in
			switch event {
			case let .Next(value):
				if skipped >= count {
					fallthrough
				} else {
					skipped++
				}

			default:
				observer.put(event)
			}
		})
	}
}

/// Treats all Events from the input signal as plain values, allowing them to be
/// manipulated just like any other value.
///
/// In other words, this brings Events “into the monad.”
public func materialize<T, E>(signal: Signal<T, E>) -> Signal<Event<T, E>, NoError> {
	return Signal { observer in
		return signal.observe(SinkOf { event in
			sendNext(observer, event)

			if event.isTerminating {
				sendCompleted(observer)
			}
		})
	}
}

/// The inverse of materialize(), this will translate a signal of `Event`
/// _values_ into a signal of those events themselves.
public func dematerialize<T, E>(signal: Signal<Event<T, E>, NoError>) -> Signal<T, E> {
	return Signal { observer in
		return signal.observe(SinkOf { event in
			switch event {
			case let .Next(innerEvent):
				observer.put(innerEvent.unbox)

			case .Error:
				fatalError()

			case .Completed:
				sendCompleted(observer)

			case .Interrupted:
				sendInterrupted(observer)
			}
		})
	}
}

private struct SampleState<T> {
	var latestValue: T? = nil
	var signalCompleted: Bool = false
	var samplerCompleted: Bool = false
}

/// Forwards the latest value from `signal` whenever `sampler` sends a Next
/// event.
///
/// If `sampler` fires before a value has been observed on `signal`, nothing
/// happens.
///
/// Returns a signal that will send values from `signal`, sampled (possibly
/// multiple times) by `sampler`, then complete once both input signals have
/// completed, or interrupt if either input signal is interrupted.
public func sampleOn<T, E>(sampler: Signal<(), NoError>)(signal: Signal<T, E>) -> Signal<T, E> {
	return Signal { observer in
		let state = Atomic(SampleState<T>())

		let signalDisposable = signal.observe(next: { value in
			state.modify { (var st) in
				st.latestValue = value
				return st
			}

			return
		}, error: { error in
			sendError(observer, error)
		}, completed: {
			let oldState = state.modify { (var st) in
				st.signalCompleted = true
				return st
			}

			if oldState.samplerCompleted {
				sendCompleted(observer)
			}
		}, interrupted: {
			sendInterrupted(observer)
		})

		let samplerDisposable = sampler.observe(next: { _ in
			if let value = state.value.latestValue {
				sendNext(observer, value)
			}
		}, completed: {
			let oldState = state.modify { (var st) in
				st.samplerCompleted = true
				return st
			}

			if oldState.signalCompleted {
				sendCompleted(observer)
			}
		}, interrupted: {
			sendInterrupted(observer)
		})

		return CompositeDisposable(ignoreNil([ signalDisposable, samplerDisposable ]))
	}
}

/// Forwards events from `signal` until `trigger` sends a Next or Completed
/// event, at which point the returned signal will complete.
public func takeUntil<T, E>(trigger: Signal<(), NoError>)(signal: Signal<T, E>) -> Signal<T, E> {
	return Signal { observer in
		let signalDisposable = signal.observe(observer)
		let triggerDisposable = trigger.observe(SinkOf { event in
			switch event {
			case .Next, .Completed:
				sendCompleted(observer)

			case .Error, .Interrupted:
				break
			}
		})

		return CompositeDisposable(ignoreNil([ signalDisposable, triggerDisposable ]))
	}
}

/// Forwards events from `signal` with history: values of the returned signal
/// are a tuple whose first member is the previous value and whose second member
/// is the current value. `initial` is supplied as the first member when `signal`
/// sends its first value.
public func combinePrevious<T, E>(initial: T)(signal: Signal<T, E>) -> Signal<(T, T), E> {
	return signal |> scan((initial, initial)) { previousCombinedValues, newValue in
		return (previousCombinedValues.1, newValue)
	}
}

/// Like `scan`, but sends only the final value and then immediately completes.
public func reduce<T, U, E>(initial: U, combine: (U, T) -> U)(signal: Signal<T, E>) -> Signal<U, E> {
	// We need to handle the special case in which `signal` sends no values.
	// We'll do that by sending `initial` on the output signal (before taking
	// the last value).
	let (scannedSignalWithInitialValue: Signal<U, E>, outputSignalObserver) = Signal.pipe()
	let outputSignal = scannedSignalWithInitialValue |> takeLast(1)

	// Now that we've got takeLast() listening to the piped signal, send that initial value.
	sendNext(outputSignalObserver, initial)

	// Pipe the scanned input signal into the output signal.
	signal |> scan(initial, combine) |> observe(outputSignalObserver)

	return outputSignal
}

/// Aggregates `signal`'s values into a single combined value. When `signal` emits
/// its first value, `combine` is invoked with `initial` as the first argument and
/// that emitted value as the second argument. The result is emitted from the
/// signal returned from `reduce`. That result is then passed to `combine` as the
/// first argument when the next value is emitted, and so on.
public func scan<T, U, E>(initial: U, combine: (U, T) -> U)(signal: Signal<T, E>) -> Signal<U, E> {
	return Signal { observer in
		var accumulator = initial

		return signal.observe(Signal.Observer { event in
			observer.put(event.map { value in
				accumulator = combine(accumulator, value)
				return accumulator
			})
		})
	}
}

/// Forwards only those values from `signal` which are not duplicates of the
/// immedately preceding value. The first value is always forwarded.
public func skipRepeats<T: Equatable, E>(signal: Signal<T, E>) -> Signal<T, E> {
	return signal |> skipRepeats { $0 == $1 }
}

/// Forwards only those values from `signal` which do not pass `isRepeat` with
/// respect to the previous value. The first value is always forwarded.
public func skipRepeats<T, E>(isRepeat: (T, T) -> Bool)(signal: Signal<T, E>) -> Signal<T, E> {
	return signal
		|> map { Optional($0) }
		|> combinePrevious(nil)
		|> filter {
			switch $0 {
			case let (.Some(a), .Some(b)) where isRepeat(a, b):
				return false
			default:
				return true
			}
		}
		|> map { $0.1! }
}

/// Does not forward any values from `signal` until `predicate` returns false,
/// at which point the returned signal behaves exactly like `signal`.
public func skipWhile<T, E>(predicate: T -> Bool)(signal: Signal<T, E>) -> Signal<T, E> {
	return Signal { observer in
		var shouldSkip = true

		return signal.observe(SinkOf { event in
			switch event {
			case let .Next(value):
				shouldSkip = shouldSkip && predicate(value.unbox)
				if !shouldSkip {
					fallthrough
				}

			default:
				observer.put(event)
			}
		})
	}
}

/// Forwards events from `signal` until `replacement` begins sending events.
///
/// Returns a signal which passes through `Next`, `Error`, and `Interrupted`
/// events from `signal` until `replacement` sends an event, at which point the
/// returned signal will send that event and switch to passing through events
/// from `replacement` instead, regardless of whether `signal` has sent events
/// already.
public func takeUntilReplacement<T, E>(replacement: Signal<T, E>)(signal: Signal<T, E>) -> Signal<T, E> {
	return Signal { observer in
		let signalDisposable = signal.observe(SinkOf { event in
			switch event {
			case .Completed:
				break

			case .Next, .Error, .Interrupted:
				observer.put(event)
			}
		})

		let replacementDisposable = replacement.observe(SinkOf { event in
			signalDisposable?.dispose()
			observer.put(event)
		})

		return CompositeDisposable(ignoreNil([ signalDisposable, replacementDisposable ]))
	}
}

/// Waits until `signal` completes and then forwards the final `count` values
/// on the returned signal.
public func takeLast<T, E>(count: Int)(signal: Signal<T, E>) -> Signal<T, E> {
	return Signal { observer in
		var buffer = [T]()
		buffer.reserveCapacity(count)

		return signal.observe(next: { value in
			// To avoid exceeding the reserved capacity of the buffer, we remove then add.
			// Remove elements until we have room to add one more.
			while (buffer.count + 1) > count {
				buffer.removeAtIndex(0)
			}

			buffer.append(value)
		}, error: { error in
			sendError(observer, error)
		}, completed: {
			for bufferedValue in buffer {
				sendNext(observer, bufferedValue)
			}

			sendCompleted(observer)
		}, interrupted: {
			sendInterrupted(observer)
		})
	}
}

/// Forwards any values from `signal` until `predicate` returns false,
/// at which point the returned signal will complete.
public func takeWhile<T, E>(predicate: T -> Bool)(signal: Signal<T, E>) -> Signal<T, E> {
	return Signal { observer in
		return signal.observe(SinkOf { event in
			switch event {
			case let .Next(value):
				if predicate(value.unbox) {
					fallthrough
				} else {
					sendCompleted(observer)
				}

			default:
				observer.put(event)
			}
		})
	}
}

private struct ZipState<T> {
	var values: [T] = []
	var completed = false

	var isFinished: Bool {
		return values.isEmpty && completed
	}
}

/// Zips elements of two signals into pairs. The elements of any Nth pair
/// are the Nth elements of the two input signals.
public func zipWith<T, U, E>(otherSignal: Signal<U, E>)(signal: Signal<T, E>) -> Signal<(T, U), E> {
	return Signal { observer in
		let initialStates: (ZipState<T>, ZipState<U>) = (ZipState(), ZipState())
		let states: Atomic<(ZipState<T>, ZipState<U>)> = Atomic(initialStates)

		let flush = { () -> () in
			var originalStates: (ZipState<T>, ZipState<U>)!
			states.modify { states in
				originalStates = states

				var updatedStates = states
				let extractCount = min(states.0.values.count, states.1.values.count)

				removeRange(&updatedStates.0.values, 0 ..< extractCount)
				removeRange(&updatedStates.1.values, 0 ..< extractCount)
				return updatedStates
			}

			while !originalStates.0.values.isEmpty && !originalStates.1.values.isEmpty {
				let left = originalStates.0.values.removeAtIndex(0)
				let right = originalStates.1.values.removeAtIndex(0)
				sendNext(observer, (left, right))
			}

			if originalStates.0.isFinished || originalStates.1.isFinished {
				sendCompleted(observer)
			}
		}

		let onError = { sendError(observer, $0) }
		let onInterrupted = { sendInterrupted(observer) }

		let signalDisposable = signal.observe(next: { value in
			states.modify { (var states) in
				states.0.values.append(value)
				return states
			}

			flush()
		}, error: onError, completed: {
			states.modify { (var states) in
				states.0.completed = true
				return states
			}

			flush()
		}, interrupted: onInterrupted)

		let otherDisposable = otherSignal.observe(next: { value in
			states.modify { (var states) in
				states.1.values.append(value)
				return states
			}

			flush()
		}, error: onError, completed: {
			states.modify { (var states) in
				states.1.completed = true
				return states
			}

			flush()
		}, interrupted: onInterrupted)

		return CompositeDisposable(ignoreNil([ signalDisposable, otherDisposable ]))
	}
}

/// Applies `operation` to values from `signal` with `Success`ful results
/// forwarded on the returned signal and `Failure`s sent as `Error` events.
public func try<T, E>(operation: T -> Result<(), E>)(signal: Signal<T, E>) -> Signal<T, E> {
	return signal |> tryMap { value in
		return operation(value).map {
			return value
		}
	}
}

/// Applies `operation` to values from `signal` with `Success`ful results mapped
/// on the returned signal and `Failure`s sent as `Error` events.
public func tryMap<T, U, E>(operation: T -> Result<U, E>)(signal: Signal<T, E>) -> Signal<U, E> {
	return Signal { observer in
		signal.observe(next: { value in
			switch operation(value) {
			case let .Success(val):
				sendNext(observer, val.unbox)

			case let .Failure(err):
				sendError(observer, err.unbox)
			}
		}, error: { error in
			sendError(observer, error)
		}, completed: {
			sendCompleted(observer)
		}, interrupted: {
			sendInterrupted(observer)
		})
	}
}

/// Throttle values sent by the receiver, so that at least `interval`
/// seconds pass between each, then forwards them on the given scheduler.
///
/// If multiple values are received before the interval has elapsed, the
/// latest value is the one that will be passed on.
///
/// If the input signal terminates while a value is being throttled, that value
/// will be discarded and the returned signal will terminate immediately.
public func throttle<T, E>(interval: NSTimeInterval, onScheduler scheduler: DateSchedulerType) -> Signal<T, E> -> Signal<T, E> {
	precondition(interval >= 0)

	return { signal in
		return Signal { observer in
			let state: Atomic<ThrottleState<T>> = Atomic(ThrottleState())
			let schedulerDisposable = SerialDisposable()

			let disposable = CompositeDisposable()
			disposable.addDisposable(schedulerDisposable)

			let signalDisposable = signal.observe(SinkOf { event in
				switch event {
				case let .Next(value):
					let (_, scheduleDate) = state.modify { (var state) -> (ThrottleState<T>, NSDate) in
						state.pendingValue = value.unbox

						let proposedScheduleDate = state.previousDate?.dateByAddingTimeInterval(interval) ?? scheduler.currentDate
						let scheduleDate = proposedScheduleDate.laterDate(scheduler.currentDate)
						return (state, scheduleDate)
					}

					schedulerDisposable.innerDisposable = scheduler.scheduleAfter(scheduleDate) {
						let (_, pendingValue) = state.modify { (var state) -> (ThrottleState<T>, T?) in
							let value = state.pendingValue
							if value != nil {
								state.pendingValue = nil
								state.previousDate = scheduleDate
							}

							return (state, value)
						}
						
						if let pendingValue = pendingValue {
							sendNext(observer, pendingValue)
						}
					}

				default:
					schedulerDisposable.innerDisposable = scheduler.schedule {
						observer.put(event)
					}
				}
			})

			disposable.addDisposable(signalDisposable)
			return disposable
		}
	}
}

private struct ThrottleState<T> {
	var previousDate: NSDate? = nil
	var pendingValue: T? = nil
}

/// Combines the values of all the given signals, in the manner described by
/// `combineLatestWith`.
public func combineLatest<A, B, Error>(a: Signal<A, Error>, b: Signal<B, Error>) -> Signal<(A, B), Error> {
	return a |> combineLatestWith(b)
}

/// Combines the values of all the given signals, in the manner described by
/// `combineLatestWith`.
public func combineLatest<A, B, C, Error>(a: Signal<A, Error>, b: Signal<B, Error>, c: Signal<C, Error>) -> Signal<(A, B, C), Error> {
	return combineLatest(a, b)
		|> combineLatestWith(c)
		|> map(repack)
}

/// Combines the values of all the given signals, in the manner described by
/// `combineLatestWith`.
public func combineLatest<A, B, C, D, Error>(a: Signal<A, Error>, b: Signal<B, Error>, c: Signal<C, Error>, d: Signal<D, Error>) -> Signal<(A, B, C, D), Error> {
	return combineLatest(a, b, c)
		|> combineLatestWith(d)
		|> map(repack)
}

/// Combines the values of all the given signals, in the manner described by
/// `combineLatestWith`.
public func combineLatest<A, B, C, D, E, Error>(a: Signal<A, Error>, b: Signal<B, Error>, c: Signal<C, Error>, d: Signal<D, Error>, e: Signal<E, Error>) -> Signal<(A, B, C, D, E), Error> {
	return combineLatest(a, b, c, d)
		|> combineLatestWith(e)
		|> map(repack)
}

/// Combines the values of all the given signals, in the manner described by
/// `combineLatestWith`.
public func combineLatest<A, B, C, D, E, F, Error>(a: Signal<A, Error>, b: Signal<B, Error>, c: Signal<C, Error>, d: Signal<D, Error>, e: Signal<E, Error>, f: Signal<F, Error>) -> Signal<(A, B, C, D, E, F), Error> {
	return combineLatest(a, b, c, d, e)
		|> combineLatestWith(f)
		|> map(repack)
}

/// Combines the values of all the given signals, in the manner described by
/// `combineLatestWith`.
public func combineLatest<A, B, C, D, E, F, G, Error>(a: Signal<A, Error>, b: Signal<B, Error>, c: Signal<C, Error>, d: Signal<D, Error>, e: Signal<E, Error>, f: Signal<F, Error>, g: Signal<G, Error>) -> Signal<(A, B, C, D, E, F, G), Error> {
	return combineLatest(a, b, c, d, e, f)
		|> combineLatestWith(g)
		|> map(repack)
}

/// Combines the values of all the given signals, in the manner described by
/// `combineLatestWith`.
public func combineLatest<A, B, C, D, E, F, G, H, Error>(a: Signal<A, Error>, b: Signal<B, Error>, c: Signal<C, Error>, d: Signal<D, Error>, e: Signal<E, Error>, f: Signal<F, Error>, g: Signal<G, Error>, h: Signal<H, Error>) -> Signal<(A, B, C, D, E, F, G, H), Error> {
	return combineLatest(a, b, c, d, e, f, g)
		|> combineLatestWith(h)
		|> map(repack)
}

/// Combines the values of all the given signals, in the manner described by
/// `combineLatestWith`.
public func combineLatest<A, B, C, D, E, F, G, H, I, Error>(a: Signal<A, Error>, b: Signal<B, Error>, c: Signal<C, Error>, d: Signal<D, Error>, e: Signal<E, Error>, f: Signal<F, Error>, g: Signal<G, Error>, h: Signal<H, Error>, i: Signal<I, Error>) -> Signal<(A, B, C, D, E, F, G, H, I), Error> {
	return combineLatest(a, b, c, d, e, f, g, h)
		|> combineLatestWith(i)
		|> map(repack)
}

/// Combines the values of all the given signals, in the manner described by
/// `combineLatestWith`.
public func combineLatest<A, B, C, D, E, F, G, H, I, J, Error>(a: Signal<A, Error>, b: Signal<B, Error>, c: Signal<C, Error>, d: Signal<D, Error>, e: Signal<E, Error>, f: Signal<F, Error>, g: Signal<G, Error>, h: Signal<H, Error>, i: Signal<I, Error>, j: Signal<J, Error>) -> Signal<(A, B, C, D, E, F, G, H, I, J), Error> {
	return combineLatest(a, b, c, d, e, f, g, h, i)
		|> combineLatestWith(j)
		|> map(repack)
}

/// Zips the values of all the given signals, in the manner described by
/// `zipWith`.
public func zip<A, B, Error>(a: Signal<A, Error>, b: Signal<B, Error>) -> Signal<(A, B), Error> {
	return a |> zipWith(b)
}

/// Zips the values of all the given signals, in the manner described by
/// `zipWith`.
public func zip<A, B, C, Error>(a: Signal<A, Error>, b: Signal<B, Error>, c: Signal<C, Error>) -> Signal<(A, B, C), Error> {
	return zip(a, b)
		|> zipWith(c)
		|> map(repack)
}

/// Zips the values of all the given signals, in the manner described by
/// `zipWith`.
public func zip<A, B, C, D, Error>(a: Signal<A, Error>, b: Signal<B, Error>, c: Signal<C, Error>, d: Signal<D, Error>) -> Signal<(A, B, C, D), Error> {
	return zip(a, b, c)
		|> zipWith(d)
		|> map(repack)
}

/// Zips the values of all the given signals, in the manner described by
/// `zipWith`.
public func zip<A, B, C, D, E, Error>(a: Signal<A, Error>, b: Signal<B, Error>, c: Signal<C, Error>, d: Signal<D, Error>, e: Signal<E, Error>) -> Signal<(A, B, C, D, E), Error> {
	return zip(a, b, c, d)
		|> zipWith(e)
		|> map(repack)
}

/// Zips the values of all the given signals, in the manner described by
/// `zipWith`.
public func zip<A, B, C, D, E, F, Error>(a: Signal<A, Error>, b: Signal<B, Error>, c: Signal<C, Error>, d: Signal<D, Error>, e: Signal<E, Error>, f: Signal<F, Error>) -> Signal<(A, B, C, D, E, F), Error> {
	return zip(a, b, c, d, e)
		|> zipWith(f)
		|> map(repack)
}

/// Zips the values of all the given signals, in the manner described by
/// `zipWith`.
public func zip<A, B, C, D, E, F, G, Error>(a: Signal<A, Error>, b: Signal<B, Error>, c: Signal<C, Error>, d: Signal<D, Error>, e: Signal<E, Error>, f: Signal<F, Error>, g: Signal<G, Error>) -> Signal<(A, B, C, D, E, F, G), Error> {
	return zip(a, b, c, d, e, f)
		|> zipWith(g)
		|> map(repack)
}

/// Zips the values of all the given signals, in the manner described by
/// `zipWith`.
public func zip<A, B, C, D, E, F, G, H, Error>(a: Signal<A, Error>, b: Signal<B, Error>, c: Signal<C, Error>, d: Signal<D, Error>, e: Signal<E, Error>, f: Signal<F, Error>, g: Signal<G, Error>, h: Signal<H, Error>) -> Signal<(A, B, C, D, E, F, G, H), Error> {
	return zip(a, b, c, d, e, f, g)
		|> zipWith(h)
		|> map(repack)
}

/// Zips the values of all the given signals, in the manner described by
/// `zipWith`.
public func zip<A, B, C, D, E, F, G, H, I, Error>(a: Signal<A, Error>, b: Signal<B, Error>, c: Signal<C, Error>, d: Signal<D, Error>, e: Signal<E, Error>, f: Signal<F, Error>, g: Signal<G, Error>, h: Signal<H, Error>, i: Signal<I, Error>) -> Signal<(A, B, C, D, E, F, G, H, I), Error> {
	return zip(a, b, c, d, e, f, g, h)
		|> zipWith(i)
		|> map(repack)
}

/// Zips the values of all the given signals, in the manner described by
/// `zipWith`.
public func zip<A, B, C, D, E, F, G, H, I, J, Error>(a: Signal<A, Error>, b: Signal<B, Error>, c: Signal<C, Error>, d: Signal<D, Error>, e: Signal<E, Error>, f: Signal<F, Error>, g: Signal<G, Error>, h: Signal<H, Error>, i: Signal<I, Error>, j: Signal<J, Error>) -> Signal<(A, B, C, D, E, F, G, H, I, J), Error> {
	return zip(a, b, c, d, e, f, g, h, i)
		|> zipWith(j)
		|> map(repack)
}

/// Forwards events from `signal` until `interval`. Then if signal isn't completed yet,
/// errors with `error` on `scheduler`.
///
/// If the interval is 0, the timeout will be scheduled immediately. The signal
/// must complete synchronously (or on a faster scheduler) to avoid the timeout.
public func timeoutWithError<T, E>(error: E, afterInterval interval: NSTimeInterval, onScheduler scheduler: DateSchedulerType) -> Signal<T, E> -> Signal<T, E> {
	precondition(interval >= 0)

	return { signal in
		return Signal { observer in
			let date = scheduler.currentDate.dateByAddingTimeInterval(interval)
			let schedulerDisposable = scheduler.scheduleAfter(date) {
				sendError(observer, error)
			}

			let signalDisposable = signal.observe(observer)
			return CompositeDisposable(ignoreNil([ signalDisposable, schedulerDisposable ]))
		}
	}
}

/// Promotes a signal that does not generate errors into one that can.
///
/// This does not actually cause errors to be generated for the given signal,
/// but makes it easier to combine with other signals that may error; for
/// example, with operators like `combineLatestWith`, `zipWith`, `join`, etc.
public func promoteErrors<T, E: ErrorType>(_: E.Type)(signal: Signal<T, NoError>) -> Signal<T, E> {
	return Signal { observer in
		return signal.observe(next: { value in
			sendNext(observer, value)
		}, completed: {
			sendCompleted(observer)
		})
	}
}

/// Signal.observe() as a free function, for easier use with |>.
public func observe<T, E, S: SinkType where S.Element == Event<T, E>>(sink: S)(signal: Signal<T, E>) -> Disposable? {
	return signal.observe(sink)
}

/// Signal.observe() as a free function, for easier use with |>.
public func observe<T, E>(next: (T -> ())? = nil, error: (E -> ())? = nil, completed: (() -> ())? = nil, interrupted: (() -> ())? = nil)(signal: Signal<T, E>) -> Disposable? {
	return signal.observe(next: next, error: error, completed: completed, interrupted: interrupted)
}
