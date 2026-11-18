fun pick(count: Int): Int = TODO("port: service/Pick.swift:12")

fun log(error: Throwable) {
    Log.error(error, msg = "failed", cat = "error")
    val ok = result.check()
}

val LocalThing = staticCompositionLocalOf<Thing> { error("Thing is provided by MainActivity") }
