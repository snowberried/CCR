package com.snowberried.ctcinereviewer

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp

internal object CcrColors {
    val Canvas = Color(0xFF05090E)
    val Shell = Color(0xFF071018)
    val TopBar = Color(0xFF08111A)
    val Panel = Color(0xFF0B151F)
    val Raised = Color(0xFF0D1924)
    val Card = Color(0xFF0E1A25)
    val Control = Color(0xFF101B26)
    val Pressed = Color(0xFF0B1620)
    val NeutralHover = Color(0xFF152331)
    val Border = Color(0xFF263746)
    val StrongBorder = Color(0xFF344B5F)
    val VideoBorder = Color(0xFF2A3947)
    val PrimaryBlue = Color(0xFF168FF0)
    val ActiveBlue = Color(0xFF1298FF)
    val FocusBlue = Color(0xFF57B9FF)
    val PrimaryText = Color(0xFFF1F6FA)
    val SecondaryText = Color(0xFFBCC7D2)
    val MutedText = Color(0xFF7F8D9B)
    val Danger = Color(0xFFFF6B78)
}

private val CcrColorScheme = darkColorScheme(
    primary = CcrColors.PrimaryBlue,
    onPrimary = CcrColors.PrimaryText,
    background = CcrColors.Canvas,
    onBackground = CcrColors.PrimaryText,
    surface = CcrColors.Panel,
    onSurface = CcrColors.PrimaryText,
    surfaceVariant = CcrColors.Raised,
    onSurfaceVariant = CcrColors.SecondaryText,
    outline = CcrColors.Border,
    outlineVariant = CcrColors.StrongBorder,
    error = CcrColors.Danger,
)

private val CcrTypography = Typography(
    titleLarge = TextStyle(fontSize = 18.sp, lineHeight = 24.sp, fontWeight = FontWeight.SemiBold),
    titleMedium = TextStyle(fontSize = 16.sp, lineHeight = 22.sp, fontWeight = FontWeight.SemiBold),
    bodyMedium = TextStyle(fontSize = 14.sp, lineHeight = 20.sp, fontWeight = FontWeight.Normal),
    bodySmall = TextStyle(fontSize = 13.sp, lineHeight = 18.sp, fontWeight = FontWeight.Normal),
    labelLarge = TextStyle(fontSize = 16.sp, lineHeight = 20.sp, fontWeight = FontWeight.SemiBold),
    labelMedium = TextStyle(fontSize = 13.sp, lineHeight = 18.sp, fontWeight = FontWeight.Medium),
)

@Composable
internal fun CcrTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = CcrColorScheme,
        typography = CcrTypography,
        content = content,
    )
}
