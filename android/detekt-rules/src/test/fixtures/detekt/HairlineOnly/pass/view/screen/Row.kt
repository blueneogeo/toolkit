@Composable
fun Row() {
    Column {
        Hairline()
        Box(Modifier.fillMaxWidth().height(2.dp).background(Palette.linen))
        Box(Modifier.fillMaxWidth().height(1.dp).background(Palette.coral))
        TurnDivider()
    }
}
