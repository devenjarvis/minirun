import Foundation

/// Helper utilities for coordinate calculations and screen dimensions
struct CoordinateHelpers {
    
    // MARK: - Common Screen Dimensions
    
    enum DeviceScreen {
        case iPhone15           // 390x844
        case iPhone15Plus       // 430x932
        case iPhone15Pro        // 393x852
        case iPhone15ProMax     // 430x932
        case iPadMini          // 744x1133
        case iPadAir           // 820x1180
        case iPadPro11         // 834x1194
        case iPadPro13         // 1024x1366
        
        var dimensions: (width: Double, height: Double) {
            switch self {
            case .iPhone15:
                return (390, 844)
            case .iPhone15Plus:
                return (430, 932)
            case .iPhone15Pro:
                return (393, 852)
            case .iPhone15ProMax:
                return (430, 932)
            case .iPadMini:
                return (744, 1133)
            case .iPadAir:
                return (820, 1180)
            case .iPadPro11:
                return (834, 1194)
            case .iPadPro13:
                return (1024, 1366)
            }
        }
        
        var description: String {
            switch self {
            case .iPhone15: return "iPhone 15"
            case .iPhone15Plus: return "iPhone 15 Plus"
            case .iPhone15Pro: return "iPhone 15 Pro"
            case .iPhone15ProMax: return "iPhone 15 Pro Max"
            case .iPadMini: return "iPad mini"
            case .iPadAir: return "iPad Air"
            case .iPadPro11: return "iPad Pro 11-inch"
            case .iPadPro13: return "iPad Pro 12.9-inch"
            }
        }
    }
    
    // MARK: - Percentage-based Coordinates
    
    /// Convert percentage-based coordinates to absolute coordinates
    /// - Parameters:
    ///   - percentX: X coordinate as percentage (0.0 to 1.0)
    ///   - percentY: Y coordinate as percentage (0.0 to 1.0)
    ///   - screenWidth: Screen width in points
    ///   - screenHeight: Screen height in points
    /// - Returns: Absolute coordinates (x, y)
    static func percentToAbsolute(
        percentX: Double,
        percentY: Double,
        screenWidth: Double,
        screenHeight: Double
    ) -> (x: Double, y: Double) {
        let x = percentX * screenWidth
        let y = percentY * screenHeight
        return (x, y)
    }
    
    /// Convert absolute coordinates to percentage-based coordinates
    /// - Parameters:
    ///   - x: Absolute X coordinate
    ///   - y: Absolute Y coordinate
    ///   - screenWidth: Screen width in points
    ///   - screenHeight: Screen height in points
    /// - Returns: Percentage coordinates (percentX, percentY)
    static func absoluteToPercent(
        x: Double,
        y: Double,
        screenWidth: Double,
        screenHeight: Double
    ) -> (percentX: Double, percentY: Double) {
        let percentX = x / screenWidth
        let percentY = y / screenHeight
        return (percentX, percentY)
    }
    
    // MARK: - Common UI Areas
    
    /// Get coordinates for common UI areas
    enum UIArea {
        case center
        case topLeft
        case topRight
        case bottomLeft
        case bottomRight
        case topCenter
        case bottomCenter
        case leftCenter
        case rightCenter
        case statusBar
        case homeIndicator
        case navigationBar
        case tabBar
        
        func coordinates(screenWidth: Double, screenHeight: Double) -> (x: Double, y: Double) {
            switch self {
            case .center:
                return (screenWidth / 2, screenHeight / 2)
            case .topLeft:
                return (50, 50)
            case .topRight:
                return (screenWidth - 50, 50)
            case .bottomLeft:
                return (50, screenHeight - 50)
            case .bottomRight:
                return (screenWidth - 50, screenHeight - 50)
            case .topCenter:
                return (screenWidth / 2, 50)
            case .bottomCenter:
                return (screenWidth / 2, screenHeight - 50)
            case .leftCenter:
                return (50, screenHeight / 2)
            case .rightCenter:
                return (screenWidth - 50, screenHeight / 2)
            case .statusBar:
                return (screenWidth / 2, 25) // Top status bar area
            case .homeIndicator:
                return (screenWidth / 2, screenHeight - 20) // Bottom home indicator
            case .navigationBar:
                return (screenWidth / 2, 100) // Navigation bar area
            case .tabBar:
                return (screenWidth / 2, screenHeight - 100) // Tab bar area
            }
        }
    }
    
    // MARK: - Gesture Helpers
    
    /// Generate swipe coordinates for common gestures
    enum SwipeDirection {
        case up, down, left, right
        
        func coordinates(
            screenWidth: Double,
            screenHeight: Double,
            distance: Double = 200
        ) -> (startX: Double, startY: Double, endX: Double, endY: Double) {
            let centerX = screenWidth / 2
            let centerY = screenHeight / 2
            
            switch self {
            case .up:
                return (centerX, centerY + distance/2, centerX, centerY - distance/2)
            case .down:
                return (centerX, centerY - distance/2, centerX, centerY + distance/2)
            case .left:
                return (centerX + distance/2, centerY, centerX - distance/2, centerY)
            case .right:
                return (centerX - distance/2, centerY, centerX + distance/2, centerY)
            }
        }
    }
    
    // MARK: - Safe Area Helpers
    
    /// Calculate safe area coordinates avoiding system UI elements
    static func safeAreaCoordinates(
        screenWidth: Double,
        screenHeight: Double,
        margin: Double = 50
    ) -> (x: Double, y: Double, width: Double, height: Double) {
        let x = margin
        let y = margin + 44 // Account for status bar
        let width = screenWidth - (margin * 2)
        let height = screenHeight - (margin * 2) - 44 - 34 // Account for status bar and home indicator
        return (x, y, width, height)
    }
    
    // MARK: - Grid Helpers
    
    /// Generate grid coordinates for systematic testing
    static func gridCoordinates(
        screenWidth: Double,
        screenHeight: Double,
        rows: Int,
        columns: Int,
        margin: Double = 50
    ) -> [(x: Double, y: Double)] {
        var coordinates: [(x: Double, y: Double)] = []
        
        let safeArea = safeAreaCoordinates(screenWidth: screenWidth, screenHeight: screenHeight, margin: margin)
        let cellWidth = safeArea.width / Double(columns)
        let cellHeight = safeArea.height / Double(rows)
        
        for row in 0..<rows {
            for col in 0..<columns {
                let x = safeArea.x + (Double(col) * cellWidth) + (cellWidth / 2)
                let y = safeArea.y + (Double(row) * cellHeight) + (cellHeight / 2)
                coordinates.append((x, y))
            }
        }
        
        return coordinates
    }
    
    // MARK: - Validation Helpers
    
    /// Validate that coordinates are within screen bounds
    static func validateCoordinates(
        x: Double,
        y: Double,
        screenWidth: Double,
        screenHeight: Double
    ) -> Bool {
        return x >= 0 && x <= screenWidth && y >= 0 && y <= screenHeight
    }
    
    /// Clamp coordinates to screen bounds
    static func clampCoordinates(
        x: Double,
        y: Double,
        screenWidth: Double,
        screenHeight: Double
    ) -> (x: Double, y: Double) {
        let clampedX = max(0, min(x, screenWidth))
        let clampedY = max(0, min(y, screenHeight))
        return (clampedX, clampedY)
    }
} 