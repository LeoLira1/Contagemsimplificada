import 'dart:async';

import 'package:flutter/material.dart';

import 'config_page.dart';
import 'contagem_page.dart';
import 'tema.dart';
import 'turso_service.dart';

void main() {
  runApp(const AppContagem());
}

class AppContagem extends StatelessWidget {
  const AppContagem({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Contagem CAMDA',
      debugShowCheckedModeBanner: false,
      theme: temaCamda(),
      home: const Abertura(),
    );
  }
}

/// Decide o que mostrar na abertura: a configuração, quando ainda não há
/// credenciais salvas, ou a lista de contagem.
class Abertura extends StatefulWidget {
  const Abertura({super.key});

  @override
  State<Abertura> createState() => _AberturaState();
}

class _AberturaState extends State<Abertura> {
  bool? _configurado;

  @override
  void initState() {
    super.initState();
    _decidir();
  }

  Future<void> _decidir() async {
    final tem = await TursoService().temCredenciais();
    if (tem) {
      // Dispara a conexão sem esperar por ela: a ContagemPage garante a
      // conexão antes de consultar, e adiantar o handshake aqui tira esse
      // tempo do caminho da primeira consulta.
      unawaited(TursoService().init());
    }
    if (!mounted) return;
    setState(() => _configurado = tem);
  }

  @override
  Widget build(BuildContext context) {
    final configurado = _configurado;
    if (configurado == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (!configurado) {
      // Primeiro uso: a configuração é a tela raiz, então não há para onde
      // voltar — ela avisa por callback em vez de tentar um pop.
      return ConfigPage(
        primeiroUso: true,
        aoConcluir: () => setState(() => _configurado = true),
      );
    }
    return const ContagemPage();
  }
}
