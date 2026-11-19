import CoreGraphics

enum ShakeSensitivity: String, CaseIterable, Identifiable {
    case low, medium, high

    var id: Self { self }

    var title: String {
        switch self {
        case .low: "Baja"
        case .medium: "Media"
        case .high: "Alta"
        }
    }

    var strokeLength: CGFloat {
        switch self {
        case .low: 62
        case .medium: 43
        case .high: 29
        }
    }
}

struct CursorShake {
    private var lastPosition: CGPoint?
    private var lastMotionTime = 0.0
    private var stroke: Stroke?
    private var latched = false

    mutating func sample(_ point: CGPoint, at time: Double, dragging: Bool, sensitivity: ShakeSensitivity) -> Bool {
        guard !dragging else {
            self = Self()
            return false
        }
        guard let previous = lastPosition else {
            lastPosition = point
            lastMotionTime = time
            return false
        }
        guard max(abs(point.x - previous.x), abs(point.y - previous.y)) >= 1 else { return false }
        lastPosition = point
        if time - lastMotionTime >= 0.16 {
            latched = false
            stroke = nil
        }
        lastMotionTime = time
        guard !latched else { return false }

        var candidate = stroke ?? Stroke(origin: previous, start: time)
        let distance = sensitivity.strokeLength
        if time - candidate.start > 0.62 || max(abs(point.x - candidate.origin.x), abs(point.y - candidate.origin.y)) > 245 {
            candidate = Stroke(origin: previous, start: time)
        }
        latched = candidate.advance(to: point, distance: distance)
        stroke = latched ? nil : candidate
        return latched
    }

    private struct Stroke {
        let origin: CGPoint
        let start: Double
        var horizontal: Bool?
        var direction: CGFloat = 0
        var extreme: CGFloat = 0
        var reversals = 0

        mutating func advance(to point: CGPoint, distance: CGFloat) -> Bool {
            let dx = point.x - origin.x
            let dy = point.y - origin.y
            if let horizontal {
                let along = horizontal ? dx : dy
                let across = horizontal ? dy : dx
                if abs(across) > max(70, distance) {
                    self.horizontal = nil
                    reversals = 0
                } else if (along - extreme) * direction >= 0 {
                    extreme = along
                } else if abs(along - extreme) >= distance {
                    extreme = along
                    direction = -direction
                    reversals += 1
                }
            } else if max(abs(dx), abs(dy)) >= distance {
                let horizontal = abs(dx) >= abs(dy)
                self.horizontal = horizontal
                extreme = horizontal ? dx : dy
                direction = extreme > 0 ? 1 : -1
            }
            return reversals >= 3
        }
    }
}
