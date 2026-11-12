// swift-tools-version: 6.0
import PackageDescription

// MSSQL 은 Homebrew FreeTDS(brew install freetds)의 DB-Library 를 사용한다. (사내 전용, 외부 배포 안 함)
let freetdsLib = "/opt/homebrew/opt/freetds/lib"

let package = Package(
    name: "GodDB",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "GodDB", targets: ["GodDB"])
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/mysql-nio.git", from: "1.9.0"),
        // 결과를 텍스트 형식으로 받도록 한 줄 패치한 사본 (Vendor/postgres-nio/GODDB_PATCH.md 참고)
        .package(path: "Vendor/postgres-nio"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.25.0"),
    ],
    targets: [
        .systemLibrary(name: "CFreeTDS", path: "Sources/CFreeTDS"),
        .target(
            name: "GodDBCore",
            dependencies: [
                .product(name: "MySQLNIO", package: "mysql-nio"),
                .product(name: "PostgresNIO", package: "postgres-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                "CFreeTDS",
            ],
            linkerSettings: [.unsafeFlags(["-L\(freetdsLib)", "-Xlinker", "-rpath", "-Xlinker", freetdsLib])]
        ),
        .executableTarget(
            name: "GodDB",
            dependencies: ["GodDBCore"]
        ),
        .testTarget(
            name: "GodDBCoreTests",
            dependencies: ["GodDBCore"]
        )
    ],
    swiftLanguageModes: [.v5]
)
