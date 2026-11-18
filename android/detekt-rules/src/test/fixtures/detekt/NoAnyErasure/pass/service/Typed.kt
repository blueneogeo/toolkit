class Key(val raw: ByteArray) {
    override fun equals(other: Any?): Boolean = other is Key && raw.contentEquals(other.raw)

    override fun hashCode(): Int = raw.contentHashCode()
}

fun <T : Any> firstOf(items: List<T>): T? = items.firstOrNull()

fun parse(notification: Map<String, Any?>): String? = notification["id"] as? String

fun format(template: String, vararg args: Any): String = String.format(template, *args)
