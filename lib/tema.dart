import 'package:flutter/material.dart';

/// Paleta do dashboard CAMDA, repetida aqui para o conferente reconhecer as
/// mesmas cores que o gestor vê na tela do escritório: verde é OK, vermelho é
/// divergência, âmbar é pendente. Cor aqui é linguagem operacional, não
/// decoração.
class CoresCamda {
  static const fundo = Color(0xFF0E1117);
  static const superficie = Color(0xFF161B22);
  static const superficieAlta = Color(0xFF1C2430);
  static const borda = Color(0xFF1E293B);

  static const verde = Color(0xFF00D68F);
  static const vermelho = Color(0xFFFF4757);
  static const ambar = Color(0xFFFFA502);
  static const azul = Color(0xFF3B82F6);
  static const roxo = Color(0xFFA855F7);

  static const texto = Color(0xFFE0E6ED);
  static const textoFraco = Color(0xFF94A3B8);
  static const textoApagado = Color(0xFF64748B);
}

ThemeData temaCamda() {
  final base = ThemeData.dark(useMaterial3: true);
  return base.copyWith(
    scaffoldBackgroundColor: CoresCamda.fundo,
    colorScheme: base.colorScheme.copyWith(
      primary: CoresCamda.verde,
      secondary: CoresCamda.azul,
      surface: CoresCamda.superficie,
      error: CoresCamda.vermelho,
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: CoresCamda.superficie,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      centerTitle: false,
    ),
    dividerTheme: const DividerThemeData(color: CoresCamda.borda, space: 1),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: CoresCamda.superficieAlta,
      contentTextStyle: TextStyle(color: CoresCamda.texto),
      behavior: SnackBarBehavior.floating,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: CoresCamda.superficie,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: CoresCamda.borda),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: CoresCamda.borda),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: CoresCamda.azul),
      ),
      hintStyle: const TextStyle(color: CoresCamda.textoApagado),
    ),
  );
}
