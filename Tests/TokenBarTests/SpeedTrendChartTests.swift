import Foundation
import Testing
@testable import TokenBar

@Suite("Speed trend chart geometry")
struct SpeedTrendChartTests {
    @Test("Empty or invalid measurements leave the plot empty", arguments: [
        [], [0], [-1], [Double.infinity], [Double.nan], [10, Double.nan],
    ])
    func invalidData(rates: [Double]) {
        #expect(SpeedTrendChartGeometry.normalizedPoints(rates: rates).isEmpty)
    }

    @Test("Round order is evenly spaced with a zero baseline and the final value at the right")
    func plotsActualRates() {
        let locations = SpeedTrendChartGeometry.normalizedPoints(rates: [20, 40, 10])
        #expect(locations == [CGPoint(x: 0, y: 0.5), CGPoint(x: 0.5, y: 0), CGPoint(x: 1, y: 0.75)])
    }

    @Test("Single points, constant rates and extreme finite rates stay in bounds")
    func boundedData() {
        #expect(SpeedTrendChartGeometry.normalizedPoints(rates: [50]) == [CGPoint(x: 0.5, y: 0)])
        #expect(SpeedTrendChartGeometry.normalizedPoints(rates: [50, 50]).map(\.y) == [0, 0])
        let points = SpeedTrendChartGeometry.normalizedPoints(rates: [.leastNonzeroMagnitude, .greatestFiniteMagnitude])
        #expect(points.count == 2)
        #expect(points.allSatisfy { $0.x.isFinite && $0.y.isFinite && (0 ... 1).contains($0.x) && (0 ... 1).contains($0.y) })
    }
    @Test("Readable upper bounds preserve finite extreme and fractional rates")
    func readableBounds() {
        #expect(SpeedTrendChartGeometry.niceMaximum(67.2) == 75)
        #expect(SpeedTrendChartGeometry.niceMaximum(0.004) == 0.005)
        #expect(SpeedTrendChartGeometry.niceMaximum(0) == 1)
        #expect(SpeedTrendChartGeometry.niceMaximum(.greatestFiniteMagnitude) == .greatestFiniteMagnitude)
        #expect(SpeedTrendChartGeometry.niceMaximum(.leastNonzeroMagnitude) >= .leastNonzeroMagnitude)
    }

    @Test("Smooth segments retain measured extrema and handle repeated sample positions")
    func boundedInterpolation() {
        let points = [CGPoint(x: 0, y: 30), CGPoint(x: 10, y: 5), CGPoint(x: 10, y: 20),
                      CGPoint(x: 25, y: 10), CGPoint(x: 40, y: 40)]
        let controls = SpeedTrendChartGeometry.controls(points: points)
        #expect(controls.count == points.count - 1)
        for (index, pair) in controls.enumerated() {
            let a = points[index], b = points[index + 1]
            for control in [pair.0, pair.1] {
                #expect((a.x ... b.x).contains(control.x))
                #expect((min(a.y, b.y) ... max(a.y, b.y)).contains(control.y))
                #expect(control.x.isFinite && control.y.isFinite)
            }
        }
    }

}
