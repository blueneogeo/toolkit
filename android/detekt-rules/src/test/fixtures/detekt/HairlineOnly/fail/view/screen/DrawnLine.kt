@Composable
fun Row() {
    Canvas(Modifier.fillMaxWidth()) {
        drawLine(color = Palette.linen, start = Offset.Zero, end = Offset(size.width, 0f), strokeWidth = 1.dp.toPx())
    }
}
