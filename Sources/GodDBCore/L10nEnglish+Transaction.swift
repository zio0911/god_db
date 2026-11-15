import Foundation

// 트랜잭션 (자동/수동 커밋) 번역
extension L10nEnglish {
    static let transaction: [String: String] = [
        "[%@] 롤백 · 변경 %@건 되돌림": "[%@] Rolled back · %@ changes undone",
        "[%@] 자동 커밋 끔 · 변경은 커밋할 때 반영돼요": "[%@] Auto-commit off · changes apply when you commit",
        "[%@] 자동 커밋 켬": "[%@] Auto-commit on",
        "[%@] 커밋 · 변경 %@건": "[%@] Committed · %@ changes",
        "끄면 INSERT·UPDATE·DELETE 가 트랜잭션 안에서 실행되고 [커밋] 할 때 반영돼요. (MySQL 은 CREATE·ALTER·DROP 이 자동 커밋돼요)": "When off, INSERT · UPDATE · DELETE run inside a transaction and apply when you press Commit. (MySQL auto-commits CREATE · ALTER · DROP)",
        "롤백": "Rollback",
        "롤백 실패": "Rollback failed",
        "롤백하고 종료": "Roll Back and Quit",
        "연결을 끊기": "disconnecting",
        "열린 트랜잭션에 변경 %@건이 있어요. %@ 전에 커밋하거나 롤백해 주세요.": "The open transaction has %@ changes. Commit or roll back before %@.",
        "열린 트랜잭션의 변경을 DB 에 반영해요": "Apply the open transaction's changes to the database",
        "열린 트랜잭션의 변경을 모두 되돌려요": "Undo all changes in the open transaction",
        "자동 커밋": "Auto-commit",
        "자동 커밋 전환 실패": "Could not switch auto-commit",
        "자동 커밋을 켜기": "turning auto-commit on",
        "접속 %@개에 커밋하지 않은 변경 %@건이 있어요. 종료하면 되돌려져요(롤백).": "%@ connections have %@ uncommitted changes. Quitting rolls them back.",
        "커밋": "Commit",
        "커밋 실패": "Commit failed",
        "커밋하지 않은 변경이 있어요": "Uncommitted changes",
        "커밋하지 않은 트랜잭션이 있어요": "There are uncommitted transactions",
        "커밋하지 않은 트랜잭션이 있어요. 먼저 커밋하거나 롤백해 주세요.": "There is an uncommitted transaction. Commit or roll back first.",
        "트랜잭션 · 변경 %@건": "Transaction · %@ changes",
    ]
}
