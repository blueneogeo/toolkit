fun greet(name: String, times: Int): String = name.repeat(times)

fun later(name: String, times: Int): String = TODO("port: service/Greet.swift:4")

fun laterBlock(name: String) {
    TODO("port: service/Greet.swift:8")
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
