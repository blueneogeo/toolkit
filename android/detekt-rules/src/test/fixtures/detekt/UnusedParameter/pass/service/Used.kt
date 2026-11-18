fun greet(name: String, times: Int): String = name.repeat(times)

fun later(name: String, times: Int): String = TODO("port: service/Greet.swift:4")

fun laterBlock(name: String) {
    TODO("port: service/Greet.swift:8")
}

fun commented(modifier: String) {
    // TODO("port: view/screen/Gallery.swift:6")
}

fun isLocked(turnID: String): Boolean = false // TODO("port: model/AppState+Keys.swift:162")

fun save(key: String): Boolean {
    // TODO("port: service/KeychainService.swift:63")
    return false
}

fun defaulted(name: String, label: String = name): String = label

abstract class Base {
    abstract fun run(count: Int)

    open fun hook(count: Int) = Unit
}

class Impl : Base() {
    override fun run(count: Int) = Unit
}

fun withIgnored(ignored: Int, value: Int): Int = value

fun template(name: String): String = "hi $name"
