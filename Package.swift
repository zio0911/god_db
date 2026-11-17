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
        // CALL 결과 집합을 받도록 패치한 사본 (Vendor/mysql-nio/GODDB_PATCH.md 참고)
        .package(path: "Vendor/mysql-nio"),
        // 결과를 텍스트 형식으로 받도록 한 줄 패치한 사본 (Vendor/postgres-nio/GODDB_PATCH.md 참고)
        .package(path: "Vendor/postgres-nio"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.25.0"),
        // 자동 업데이트 (서버 없이 GitHub 릴리스에 첨부한 appcast.xml 을 읽는다)
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
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
            dependencies: ["GodDBCore", .product(name: "Sparkle", package: "Sparkle")],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(
            name: "GodDBCoreTests",
            dependencies: ["GodDBCore"]
        )
    ],
    swiftLanguageModes: [.v5]
)
