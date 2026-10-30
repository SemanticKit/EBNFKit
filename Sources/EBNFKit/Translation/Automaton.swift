/// A deterministic finite automaton over Unicode scalars: what a terminal
/// production compiles to, so that matching it reads each character once.
///
/// The automaton is built from the production's expression by Thompson's
/// construction and the subset construction; `A - B` is the product of the
/// automata of A and B, accepting where A accepts and B does not. A
/// production that refers back to itself is not regular and has no
/// automaton.
struct Automaton: Hashable {
    /// For each state, the ranges of characters it moves on and the state
    /// each moves to, in order of the ranges. The start state is 0.
    var transitions: [[Transition]]
    /// Whether each state accepts.
    var accepting: [Bool]

    struct Transition: Hashable {
        var range: ClosedRange<UInt32>
        var target: Int
    }

    /// The state after `state` on `value`, `nil` when there is none.
    func next(_ state: Int, _ value: UInt32) -> Int? {
        transitions[state].first { $0.range.contains(value) }?.target
    }

    /// The automaton of `expression`, `nil` when the expression refers to
    /// a production that refers back to itself.
    init?(_ expression: Expression, bySymbol: [String: Production]) {
        var builder = NFA()
        guard let fragment = builder.fragment(expression, bySymbol: bySymbol, inProgress: []) else { return nil }
        self = builder.determinized(fragment).minimized()
    }

    init(transitions: [[Transition]], accepting: [Bool]) {
        self.transitions = transitions
        self.accepting = accepting
    }

    /// The automaton that accepts what `self` accepts and `other` does not.
    func subtracting(_ other: Automaton) -> Automaton {
        var index: [[Int]: Int] = [[0, 0]: 0]
        var pairs: [[Int]] = [[0, 0]]
        var transitions: [[Transition]] = []
        var accepting: [Bool] = []
        var position = 0
        while position < pairs.count {
            let (left, right) = (pairs[position][0], pairs[position][1])
            accepting.append(self.accepting[left] && !(right >= 0 && other.accepting[right]))
            var cuts = Set<UInt32>()
            for transition in self.transitions[left] { cuts.insert(transition.range.lowerBound); if transition.range.upperBound < 0x10FFFF { cuts.insert(transition.range.upperBound + 1) } }
            if right >= 0 {
                for transition in other.transitions[right] { cuts.insert(transition.range.lowerBound); if transition.range.upperBound < 0x10FFFF { cuts.insert(transition.range.upperBound + 1) } }
            }
            let sorted = cuts.sorted()
            var row: [Transition] = []
            for (offset, low) in sorted.enumerated() {
                let high = offset + 1 < sorted.count ? sorted[offset + 1] - 1 : 0x10FFFF
                guard let nextLeft = next(left, low) else { continue }
                let nextRight = right >= 0 ? (other.next(right, low) ?? -1) : -1
                let pair = [nextLeft, nextRight]
                let target: Int
                if let known = index[pair] {
                    target = known
                } else {
                    target = pairs.count
                    index[pair] = target
                    pairs.append(pair)
                }
                row.append(Transition(range: low...high, target: target))
            }
            transitions.append(Self.merged(row))
            position += 1
        }
        return Automaton(transitions: transitions, accepting: accepting)
    }

    /// The automaton with the fewest states that accepts the same strings:
    /// states are split by whether they accept, then by the blocks their
    /// characters move to, until no block splits (Moore's algorithm). The
    /// states are numbered in the order a breadth-first walk from the start
    /// reaches them.
    func minimized() -> Automaton {
        var block = accepting.map { $0 ? 1 : 0 }
        while true {
            var signatures: [[Int]: Int] = [:]
            var next: [Int] = []
            for state in transitions.indices {
                var signature = [block[state]]
                for transition in Self.merged(transitions[state].map { Transition(range: $0.range, target: block[$0.target]) }) {
                    signature += [Int(transition.range.lowerBound), Int(transition.range.upperBound), transition.target]
                }
                if let known = signatures[signature] {
                    next.append(known)
                } else {
                    signatures[signature] = signatures.count
                    next.append(signatures.count - 1)
                }
            }
            let count = Set(block).count
            block = next
            if Set(next).count == count { break }
        }
        // Number the blocks breadth first from the start.
        var number: [Int: Int] = [block[0]: 0]
        var representatives = [0]
        var position = 0
        while position < representatives.count {
            for transition in transitions[representatives[position]] where number[block[transition.target]] == nil {
                number[block[transition.target]] = representatives.count
                representatives.append(transition.target)
            }
            position += 1
        }
        return Automaton(
            transitions: representatives.map { state in
                Self.merged(transitions[state].map { Transition(range: $0.range, target: number[block[$0.target]]!) })
            },
            accepting: representatives.map { accepting[$0] }
        )
    }

    /// `row` with adjacent ranges to the same target joined.
    static func merged(_ row: [Transition]) -> [Transition] {
        var result: [Transition] = []
        for transition in row {
            if let last = result.last, last.target == transition.target, last.range.upperBound + 1 == transition.range.lowerBound {
                result[result.count - 1].range = last.range.lowerBound...transition.range.upperBound
            } else {
                result.append(transition)
            }
        }
        return result
    }
}

/// A nondeterministic automaton under construction, by Thompson's
/// construction.
private struct NFA {
    var epsilon: [[Int]] = []
    var edges: [[(ranges: [ClosedRange<UInt32>], target: Int)]] = []

    struct Fragment {
        var start: Int
        var end: Int
    }

    mutating func state() -> Int {
        epsilon.append([])
        edges.append([])
        return epsilon.count - 1
    }

    mutating func edge(_ from: Int, _ ranges: [ClosedRange<UInt32>], _ to: Int) {
        edges[from].append((ranges, to))
    }

    mutating func link(_ from: Int, _ to: Int) {
        epsilon[from].append(to)
    }

    mutating func fragment(_ expression: Expression, bySymbol: [String: Production], inProgress: Set<String>) -> Fragment? {
        switch expression {
        case .symbol(let name):
            guard !inProgress.contains(name), let production = bySymbol[name] else { return nil }
            return fragment(production.expression, bySymbol: bySymbol, inProgress: inProgress.union([name]))
        case .string(let text, _):
            let start = state()
            var current = start
            for scalar in text.unicodeScalars {
                let next = state()
                edge(current, [scalar.value...scalar.value], next)
                current = next
            }
            return Fragment(start: start, end: current)
        case .character(let value):
            let start = state()
            let end = state()
            edge(start, [value...value], end)
            return Fragment(start: start, end: end)
        case .characterClass(let characterClass):
            let start = state()
            let end = state()
            edge(start, characterClass.isNegated ? Self.complement(characterClass.ranges) : characterClass.ranges, end)
            return Fragment(start: start, end: end)
        case .sequence(let items):
            let start = state()
            var current = start
            for item in items {
                guard let inner = fragment(item, bySymbol: bySymbol, inProgress: inProgress) else { return nil }
                link(current, inner.start)
                current = inner.end
            }
            return Fragment(start: start, end: current)
        case .choice(let options):
            let start = state()
            let end = state()
            for option in options {
                guard let inner = fragment(option, bySymbol: bySymbol, inProgress: inProgress) else { return nil }
                link(start, inner.start)
                link(inner.end, end)
            }
            return Fragment(start: start, end: end)
        case .optional(let item):
            guard let inner = fragment(item, bySymbol: bySymbol, inProgress: inProgress) else { return nil }
            let start = state()
            let end = state()
            link(start, inner.start)
            link(inner.end, end)
            link(start, end)
            return Fragment(start: start, end: end)
        case .zeroOrMore(let item):
            guard let inner = fragment(item, bySymbol: bySymbol, inProgress: inProgress) else { return nil }
            let start = state()
            let end = state()
            link(start, inner.start)
            link(start, end)
            link(inner.end, inner.start)
            link(inner.end, end)
            return Fragment(start: start, end: end)
        case .oneOrMore(let item):
            guard let inner = fragment(item, bySymbol: bySymbol, inProgress: inProgress) else { return nil }
            let end = state()
            link(inner.end, inner.start)
            link(inner.end, end)
            return Fragment(start: inner.start, end: end)
        case .difference(let left, let right):
            var leftBuilder = NFA()
            var rightBuilder = NFA()
            guard let leftFragment = leftBuilder.fragment(left, bySymbol: bySymbol, inProgress: inProgress),
                  let rightFragment = rightBuilder.fragment(right, bySymbol: bySymbol, inProgress: inProgress) else { return nil }
            let automaton = leftBuilder.determinized(leftFragment).subtracting(rightBuilder.determinized(rightFragment))
            return embed(automaton)
        }
    }

    /// The automaton as a fragment of this one.
    mutating func embed(_ automaton: Automaton) -> Fragment {
        let states = automaton.transitions.indices.map { _ in state() }
        let end = state()
        for (index, row) in automaton.transitions.enumerated() {
            for transition in row { edge(states[index], [transition.range], states[transition.target]) }
            if automaton.accepting[index] { link(states[index], end) }
        }
        return Fragment(start: states[0], end: end)
    }

    static func complement(_ ranges: [ClosedRange<UInt32>]) -> [ClosedRange<UInt32>] {
        var result: [ClosedRange<UInt32>] = []
        var next: UInt32 = 0
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if range.lowerBound > next { result.append(next...(range.lowerBound - 1)) }
            next = max(next, range.upperBound == 0x10FFFF ? 0x110000 : range.upperBound + 1)
        }
        if next <= 0x10FFFF { result.append(next...0x10FFFF) }
        return result
    }

    func closure(_ states: Set<Int>) -> [Int] {
        var result = states
        var pending = Array(states)
        while let state = pending.popLast() {
            for next in epsilon[state] where result.insert(next).inserted { pending.append(next) }
        }
        return result.sorted()
    }

    /// The subset construction: a state of the automaton for each set of
    /// states the fragment can be in.
    func determinized(_ fragment: Fragment) -> Automaton {
        let start = closure([fragment.start])
        var index: [[Int]: Int] = [start: 0]
        var sets: [[Int]] = [start]
        var transitions: [[Automaton.Transition]] = []
        var accepting: [Bool] = []
        var position = 0
        while position < sets.count {
            let current = sets[position]
            accepting.append(current.contains(fragment.end))
            var cuts = Set<UInt32>()
            for state in current {
                for edge in edges[state] {
                    for range in edge.ranges {
                        cuts.insert(range.lowerBound)
                        if range.upperBound < 0x10FFFF { cuts.insert(range.upperBound + 1) }
                    }
                }
            }
            let sorted = cuts.sorted()
            var row: [Automaton.Transition] = []
            for (offset, low) in sorted.enumerated() {
                let high = offset + 1 < sorted.count ? sorted[offset + 1] - 1 : 0x10FFFF
                var targets = Set<Int>()
                for state in current {
                    for edge in edges[state] where edge.ranges.contains(where: { $0.contains(low) }) {
                        targets.insert(edge.target)
                    }
                }
                guard !targets.isEmpty else { continue }
                let next = closure(targets)
                let target: Int
                if let known = index[next] {
                    target = known
                } else {
                    target = sets.count
                    index[next] = target
                    sets.append(next)
                }
                row.append(Automaton.Transition(range: low...high, target: target))
            }
            transitions.append(Automaton.merged(row))
            position += 1
        }
        return Automaton(transitions: transitions, accepting: accepting)
    }
}
