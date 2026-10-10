import Foundation
import CoreGraphics

/// One scalable silhouette shared by the live glass mark and packaged icon.
/// Coordinates use a top-left origin. The two satellites suggest connected thoughts.
public enum OrbitComponent: Sendable { case orbit, satellites, nucleus }

public enum OrbitGeometry {
    public static func path(in rect: CGRect, component: OrbitComponent? = nil) -> CGPath {
        let side = min(rect.width, rect.height)
        var transform = CGAffineTransform(scaleX: side, y: side)
        transform.tx = rect.midX - side / 2
        transform.ty = rect.midY - side / 2
        return normalizedPath(component: component).copy(using: &transform)!
    }

    public static var normalizedPath: CGPath {
        normalizedPath(component: nil)
    }

    private static func normalizedPath(component: OrbitComponent?) -> CGPath {
        let result = CGMutablePath()
        if component == nil || component == .orbit {
          for (start, end) in [(168.0, 276.0), (-12.0, 104.0)] {
            let arc = CGMutablePath()
            arc.addArc(center: CGPoint(x: 0.5, y: 0.5), radius: 0.32,
                       startAngle: start * .pi / 180, endAngle: end * .pi / 180,
                       clockwise: false)
            var roundedArc = arc.copy(strokingWithWidth: 0.064, lineCap: .butt,
                                      lineJoin: .round, miterLimit: 1)
            // Explicit endpoint disks also keep the exported filled SVG caps round.
            for angle in [start, end] {
                let radians = angle * .pi / 180
                let center = CGPoint(x: 0.5 + cos(radians) * 0.32, y: 0.5 + sin(radians) * 0.32)
                let cap = CGPath(ellipseIn: CGRect(x: center.x - 0.032, y: center.y - 0.032,
                                                  width: 0.064, height: 0.064), transform: nil)
                roundedArc = roundedArc.union(cap)
            }
            result.addPath(roundedArc)
          }
        }
        if component == nil || component == .satellites {
          for angle in [142.0, -38.0] {
            let radians = angle * .pi / 180
            addRing(to: result, center: CGPoint(x: 0.5 + cos(radians) * 0.32,
                                               y: 0.5 + sin(radians) * 0.32),
                    radius: 0.07, width: 0.051)
          }
        }
        if component == nil || component == .nucleus {
            addRing(to: result, center: CGPoint(x: 0.5, y: 0.5), radius: 0.112, width: 0.062)
        }
        return result
    }

    private static func addRing(to path: CGMutablePath, center: CGPoint, radius: CGFloat, width: CGFloat) {
        let ring = CGPath(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                           width: radius * 2, height: radius * 2), transform: nil)
        path.addPath(ring.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 1))
    }
}
