import CarPlay
import Foundation
import MapboxDirections
import MapboxNavigationCore

/// CarPlay navigation metadata (iOS 17.4+): the maneuver data a car draws itself in its instrument
/// cluster or head-up display ("Share upcoming maneuvers with vehicle" in Apple's CarPlay guide).
///
/// It supplements the symbol and instruction CarPlay shows on its own screen. CarPlay asks for it
/// through `CPMapTemplateDelegate.mapTemplateShouldProvideNavigationMetadata(_:)`; the maneuvers
/// must then be added to the navigation session before they are set as upcoming maneuvers, and
/// `maneuverType`, `junctionType` and `trafficSide` are required on each of them.
@available(iOS 17.4, *)
enum CarPlayNavigationMetadata {
    /// Distances (meters) to the maneuver at which the session's `maneuverState` changes.
    static let prepareDistance: CLLocationDistance = 400
    static let executeDistance: CLLocationDistance = 60
    /// After a maneuver the next one is "initial" for this far, then "continue".
    static let initialDistanceTraveled: CLLocationDistance = 150

    /// Fills the metadata of the maneuver that `visualInstruction` announces: the maneuver at the
    /// end of `step`, which is the start of `upcomingStep`.
    static func apply(
        to maneuver: CPManeuver,
        visualInstruction: VisualInstructionBanner,
        step: RouteStep,
        upcomingStep: RouteStep?
    ) {
        let primary = visualInstruction.primaryInstruction
        let maneuverType = primary.maneuverType ?? upcomingStep?.maneuverType
        let direction = primary.maneuverDirection ?? upcomingStep?.maneuverDirection
        let isRoundabout = maneuverType.map(isRoundaboutManeuver) ?? false
        let exitIndex = upcomingStep?.exitIndex

        maneuver.maneuverType = cpManeuverType(
            maneuverType: maneuverType,
            direction: direction,
            exitIndex: exitIndex,
            fromTransport: step.transportType,
            toTransport: upcomingStep?.transportType
        )
        maneuver.junctionType = isRoundabout ? .roundabout : .intersection
        maneuver.trafficSide = visualInstruction.drivingSide == .left ? .left : .right

        if let names = upcomingStep?.names?.filter({ !$0.isEmpty }), !names.isEmpty {
            maneuver.roadFollowingManeuverVariants = names
        } else if let text = primary.text, !text.isEmpty {
            maneuver.roadFollowingManeuverVariants = [text]
        }
        if let exitCode = upcomingStep?.exitCodes?.first, !exitCode.isEmpty {
            maneuver.highwayExitLabel = exitCode
        }

        if let angles = junctionAngles(at: upcomingStep?.intersections?.first) {
            maneuver.junctionExitAngle = angles.exit
            maneuver.junctionElementAngles = angles.elements
        }
    }

    /// Metadata for a maneuver built from a step alone (no banner instruction yet).
    static func apply(to maneuver: CPManeuver, step: RouteStep, upcomingStep: RouteStep?) {
        let maneuverType = upcomingStep?.maneuverType ?? step.maneuverType
        let direction = upcomingStep?.maneuverDirection ?? step.maneuverDirection
        maneuver.maneuverType = cpManeuverType(
            maneuverType: maneuverType,
            direction: direction,
            exitIndex: upcomingStep?.exitIndex,
            fromTransport: step.transportType,
            toTransport: upcomingStep?.transportType
        )
        maneuver.junctionType = isRoundaboutManeuver(maneuverType) ? .roundabout : .intersection
        maneuver.trafficSide = step.drivingSide == .left ? .left : .right
        if let names = (upcomingStep ?? step).names?.filter({ !$0.isEmpty }), !names.isEmpty {
            maneuver.roadFollowingManeuverVariants = names
        }
    }

    /// Copies the metadata of `source` onto `maneuver` (CarPlay requires it on every added maneuver).
    static func copy(from source: CPManeuver, to maneuver: CPManeuver) {
        maneuver.maneuverType = source.maneuverType
        maneuver.junctionType = source.junctionType
        maneuver.trafficSide = source.trafficSide
        maneuver.roadFollowingManeuverVariants = source.roadFollowingManeuverVariants
        maneuver.junctionExitAngle = source.junctionExitAngle
        maneuver.junctionElementAngles = source.junctionElementAngles
    }

    /// How close the current maneuver is: continue → initial → prepare → execute.
    static func maneuverState(distanceRemaining: CLLocationDistance, distanceTraveled: CLLocationDistance) -> CPManeuverState {
        if distanceRemaining <= executeDistance { return .execute }
        if distanceRemaining <= prepareDistance { return .prepare }
        if distanceTraveled <= initialDistanceTraveled { return .initial }
        return .continue
    }

    // MARK: - Mapping

    static func isRoundaboutManeuver(_ type: ManeuverType) -> Bool {
        switch type {
        case .takeRoundabout, .takeRotary, .turnAtRoundabout, .exitRoundabout, .exitRotary:
            return true
        default:
            return false
        }
    }

    static func cpManeuverType(
        maneuverType: ManeuverType?,
        direction: ManeuverDirection?,
        exitIndex: Int?,
        fromTransport: TransportType,
        toTransport: TransportType?
    ) -> CPManeuverType {
        if let toTransport, toTransport == .ferry, fromTransport != .ferry { return .enter_Ferry }
        if fromTransport == .ferry, let toTransport, toTransport != .ferry { return .exitFerry }

        guard let maneuverType else { return turnType(for: direction) ?? .noTurn }

        switch maneuverType {
        case .depart:
            return direction == .uTurn ? .startRouteWithUTurn : .startRoute
        case .arrive:
            switch direction {
            case .left, .slightLeft, .sharpLeft: return .arriveAtDestinationLeft
            case .right, .slightRight, .sharpRight: return .arriveAtDestinationRight
            default: return .arriveAtDestination
            }
        case .takeRoundabout, .takeRotary, .turnAtRoundabout:
            if direction == .uTurn { return .uTurnAtRoundabout }
            if let exitIndex, let type = roundaboutExitType(exitIndex) { return type }
            return .enterRoundabout
        case .exitRoundabout, .exitRotary:
            return .exitRoundabout
        case .takeOffRamp:
            switch direction {
            case .left, .slightLeft, .sharpLeft: return .highwayOffRampLeft
            case .right, .slightRight, .sharpRight: return .highwayOffRampRight
            default: return .offRamp
            }
        case .takeOnRamp:
            return .onRamp
        case .reachFork, .merge:
            switch direction {
            case .left, .slightLeft, .sharpLeft: return .keepLeft
            case .right, .slightRight, .sharpRight: return .keepRight
            default: return .straightAhead
            }
        case .reachEnd:
            switch direction {
            case .left, .slightLeft, .sharpLeft: return .leftTurnAtEnd
            case .right, .slightRight, .sharpRight: return .rightTurnAtEnd
            default: return turnType(for: direction) ?? .noTurn
            }
        case .passNameChange:
            return turnType(for: direction).flatMap { $0 == .straightAhead ? .followRoad : $0 } ?? .followRoad
        case .continue, .useLane:
            return turnType(for: direction) ?? .straightAhead
        case .turn, .heedWarning:
            return turnType(for: direction) ?? .noTurn
        }
    }

    static func turnType(for direction: ManeuverDirection?) -> CPManeuverType? {
        switch direction {
        case .sharpLeft: return .sharpLeftTurn
        case .left: return .leftTurn
        case .slightLeft: return .slightLeftTurn
        case .straightAhead: return .straightAhead
        case .slightRight: return .slightRightTurn
        case .right: return .rightTurn
        case .sharpRight: return .sharpRightTurn
        case .uTurn: return .uTurn
        default: return nil
        }
    }

    static func roundaboutExitType(_ exitIndex: Int) -> CPManeuverType? {
        guard (1...19).contains(exitIndex) else { return nil }
        return CPManeuverType(rawValue: CPManeuverType.roundaboutExit1.rawValue + UInt(exitIndex - 1))
    }

    /// Exit and other road angles of the junction, relative to driving straight on (0°), clockwise
    /// positive, in -180...180 (Apple: a right turn is 45°–135°). Nil without heading data.
    static func junctionAngles(
        at intersection: Intersection?
    ) -> (exit: Measurement<UnitAngle>, elements: Set<Measurement<UnitAngle>>)? {
        guard let intersection,
              let approachIndex = intersection.approachIndex,
              let outletIndex = intersection.outletIndex,
              intersection.headings.indices.contains(approachIndex),
              intersection.headings.indices.contains(outletIndex)
        else { return nil }

        // `headings[approachIndex]` points back along the road we arrive on.
        let travelHeading = (intersection.headings[approachIndex] + 180).truncatingRemainder(dividingBy: 360)
        func relative(_ heading: Double) -> Measurement<UnitAngle> {
            var angle = (heading - travelHeading).truncatingRemainder(dividingBy: 360)
            if angle > 180 { angle -= 360 }
            if angle <= -180 { angle += 360 }
            return Measurement(value: angle.rounded(), unit: .degrees)
        }

        let exit = relative(intersection.headings[outletIndex])
        var elements = Set<Measurement<UnitAngle>>()
        // Every other road of the junction, the one we arrive on (180°) included.
        for (index, heading) in intersection.headings.enumerated() where index != outletIndex {
            let angle = relative(heading)
            if angle != exit { elements.insert(angle) }
        }
        return (exit, elements)
    }
}
