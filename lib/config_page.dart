import 'package:flutter/material.dart';

import 'tema.dart';
import 'turso_service.dart';

/// Tela de configuração das credenciais do Turso — o mesmo banco do dashboard
/// `camda-estoque` e do app `Gondolas`. Aparece sozinha no primeiro uso e
/// depois só pela engrenagem.
class ConfigPage extends StatefulWidget {
  /// True quando não há credenciais salvas: some o botão de voltar, porque
  /// não existe tela nenhuma atrás desta.
  final bool primeiroUso;

  /// Chamado no lugar do `pop` quando esta é a tela raiz (primeiro uso).
  final VoidCallback? aoConcluir;

  const ConfigPage({super.key, this.primeiroUso = false, this.aoConcluir});

  @override
  State<ConfigPage> createState() => _ConfigPageState();
}

class _ConfigPageState extends State<ConfigPage> {
  final _urlCtrl = TextEditingController();
  final _tokenCtrl = TextEditingController();

  bool _carregando = true;
  bool _testando = false;
  String? _erro;

  @override
  void initState() {
    super.initState();
    _carregarSalvos();
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    _tokenCtrl.dispose();
    super.dispose();
  }

  Future<void> _carregarSalvos() async {
    final (url, token) = await TursoService().lerCredenciais();
    if (!mounted) return;
    setState(() {
      _urlCtrl.text = url;
      _tokenCtrl.text = token;
      _carregando = false;
    });
  }

  Future<void> _salvar() async {
    setState(() {
      _testando = true;
      _erro = null;
    });

    // Testa antes de salvar: credencial errada gravada é uma tela de erro
    // toda vez que o app abre, e no meio do corredor ninguém quer descobrir
    // isso digitando token de novo.
    final erro = await TursoService()
        .testarCredenciais(_urlCtrl.text, _tokenCtrl.text);
    if (!mounted) return;

    if (erro != null) {
      setState(() {
        _testando = false;
        _erro = erro;
      });
      return;
    }

    await TursoService().salvarCredenciais(_urlCtrl.text, _tokenCtrl.text);
    await TursoService().init();
    if (!mounted) return;

    setState(() => _testando = false);

    final aoConcluir = widget.aoConcluir;
    if (aoConcluir != null) {
      aoConcluir();
    } else {
      Navigator.of(context).pop(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Conexão com o banco'),
        automaticallyImplyLeading: !widget.primeiroUso,
      ),
      body: _carregando
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                if (widget.primeiroUso) ...[
                  const Text(
                    'Contagem CAMDA',
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w700,
                      color: CoresCamda.texto,
                    ),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Informe a URL e o token do banco Turso da cooperativa — '
                    'os mesmos usados no dashboard de estoque e no app das '
                    'gôndolas.',
                    style: TextStyle(color: CoresCamda.textoFraco, height: 1.4),
                  ),
                  const SizedBox(height: 24),
                ],
                TextField(
                  controller: _urlCtrl,
                  autocorrect: false,
                  keyboardType: TextInputType.url,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                  decoration: const InputDecoration(
                    labelText: 'URL do banco',
                    hintText: 'libsql://seu-banco.turso.io',
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _tokenCtrl,
                  autocorrect: false,
                  maxLines: 3,
                  minLines: 1,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                  decoration: const InputDecoration(
                    labelText: 'Token de autenticação',
                    hintText: 'eyJhbGciOi...',
                  ),
                ),
                if (_erro != null) ...[
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: CoresCamda.vermelho.withValues(alpha: 0.10),
                      border: Border.all(
                        color: CoresCamda.vermelho.withValues(alpha: 0.35),
                      ),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.error_outline,
                            color: CoresCamda.vermelho, size: 20),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            _erro!,
                            style: const TextStyle(
                              color: CoresCamda.vermelho,
                              fontSize: 13,
                              height: 1.35,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: _testando ? null : _salvar,
                  style: FilledButton.styleFrom(
                    backgroundColor: CoresCamda.verde,
                    foregroundColor: Colors.black,
                    minimumSize: const Size.fromHeight(52),
                  ),
                  child: _testando
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.black),
                        )
                      : const Text('Testar e salvar',
                          style: TextStyle(fontWeight: FontWeight.w700)),
                ),
                const SizedBox(height: 16),
                const Text(
                  'As credenciais ficam salvas apenas neste aparelho.',
                  textAlign: TextAlign.center,
                  style:
                      TextStyle(color: CoresCamda.textoApagado, fontSize: 12),
                ),
              ],
            ),
    );
  }
}
