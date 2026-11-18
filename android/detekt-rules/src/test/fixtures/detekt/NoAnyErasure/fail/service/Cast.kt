fun box(value: String): Int {
    val erased = value as Any
    return erased.hashCode()
}
