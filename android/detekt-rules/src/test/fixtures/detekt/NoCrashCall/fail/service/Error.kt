fun pick(kind: String): Int =
    when (kind) {
        "a" -> 1
        else -> error("unknown kind")
    }
