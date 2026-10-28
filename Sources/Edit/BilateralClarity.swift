import Foundation

/// Small bilateral grid for log-light local contrast (Durand/Dorsey; Chen/Paris/Durand).
/// Spatial and intensity weights separate detail from its base without vetoing whole areas near an edge.
/// Input is the medium-scale guide at <=640 px; only this scalar field is read back, not a full RAW bitmap.
enum BilateralClarity {
    static func residual(_ input: [Float], width: Int, height: Int, spatialSigma: Float,
                         rangeSigma: Float = 0.6) -> [Float] {
        guard width > 0, height > 0, input.count == width * height else { return [] }
        let spatial = max(spatialSigma, 1), range = max(rangeSigma, 0.1)
        let nx = Int(ceil(Float(width) / spatial)) + 7
        let ny = Int(ceil(Float(height) / spatial)) + 7
        let nz = Int(ceil(16 / range)) + 7
        var grid = [SIMD2<Float>](repeating: .zero, count: nx * ny * nz)
        var scratch = grid
        func coordinate(_ x: Int, _ y: Int, _ value: Float) -> (Int, Int, Int, Float, Float, Float) {
            let gx = Float(x) / spatial + 3, gy = Float(y) / spatial + 3, gz = (value + 8) / range + 3
            let ix = Int(gx), iy = Int(gy), iz = Int(gz)
            return (ix, iy, iz, gx - Float(ix), gy - Float(iy), gz - Float(iz))
        }
        // Trilinear splat: numerator and weight, so normalization also preserves constant borders.
        for y in 0..<height { for x in 0..<width {
            let raw = input[y * width + x], value = raw.isFinite ? min(max(raw, -8), 8) : 0
            let (ix, iy, iz, fx, fy, fz) = coordinate(x, y, value)
            for dz in 0...1 { for dy in 0...1 { for dx in 0...1 {
                let wx = dx == 0 ? 1 - fx : fx, wy = dy == 0 ? 1 - fy : fy, wz = dz == 0 ? 1 - fz : fz
                let index = ((iz + dz) * ny + iy + dy) * nx + ix + dx
                grid[index] += SIMD2(value, 1) * (wx * wy * wz)
            } } }
        } }
        // Two binomial passes per axis approximate a unit Gaussian on the compact 3D grid.
        for (stride, length) in [(1, nx), (nx, ny), (nx * ny, nz)] {
            for _ in 0..<2 {
                for index in grid.indices {
                    let position = (index / stride) % length
                    let lo = position == 0 ? index : index - stride
                    let hi = position == length - 1 ? index : index + stride
                    scratch[index] = grid[lo] * 0.25 + grid[index] * 0.5 + grid[hi] * 0.25
                }
                swap(&grid, &scratch)
            }
        }
        var result = [Float](repeating: 0, count: input.count)
        for y in 0..<height { for x in 0..<width {
            let raw = input[y * width + x], value = raw.isFinite ? min(max(raw, -8), 8) : 0
            let (ix, iy, iz, fx, fy, fz) = coordinate(x, y, value)
            var sample = SIMD2<Float>.zero
            for dz in 0...1 { for dy in 0...1 { for dx in 0...1 {
                let wx = dx == 0 ? 1 - fx : fx, wy = dy == 0 ? 1 - fy : fy, wz = dz == 0 ? 1 - fz : fz
                sample += grid[((iz + dz) * ny + iy + dy) * nx + ix + dx] * (wx * wy * wz)
            } } }
            result[y * width + x] = sample.y > 1e-8 ? value - sample.x / sample.y : 0
        } }
        return result
    }
}
