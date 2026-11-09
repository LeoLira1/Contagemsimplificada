import 'dart:async';

import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:libsql_dart/libsql_dart.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Conexão com o mesmo banco Turso usado pelo dashboard `camda-estoque` e
/// pelo app `Gondolas`.
///
/// Diferente do Gôndolas, aqui a conexão é SEMPRE remota (sem réplica local
/// com escrita offline). São dois motivos, os dois específicos da contagem:
///
/// 1. A lista de contagem é montada pelo dashboard a cada upload de planilha.
///    Conferir uma lista velha, cacheada do dia anterior, é pior do que não
///    conferir — o conferente contaria produtos que já saíram da lista.
/// 2. Confirmar um item dispara triggers no banco (`trig_contagem_to_cicli`,
///    `trig_contagem_status_ciclo`) que alimentam o inventário cíclico. Uma
///    escrita offline que só sobe depois abriria janela para conflito com o
///    mesmo item confirmado pelo dashboard.
///
/// Na prática: o app exige rede para trabalhar, e é honesto quanto a isso.
class TursoService {
  static final TursoService _instance = TursoService._internal();
  factory TursoService() => _instance;
  TursoService._internal();

  static const String keyDbUrl = 'turso_db_url';
  static const String keyDbToken = 'turso_db_token';

  static const Duration _timeoutConexao = Duration(seconds: 20);

  /// Conexões extras, só de leitura, usadas para carregar a lista.
  ///
  /// O cliente remoto do libsql manda um pedido de cada vez por conexão, e
  /// cada consulta são duas idas ao servidor (descrever + executar). As sete
  /// consultas da lista, numa conexão só, viravam 14 idas em fila — com o
  /// 4G da loja, vários segundos de tela vazia. Espalhadas por conexões
  /// separadas elas andam ao mesmo tempo.
  static const int _leitoresExtras = 3;

  LibsqlClient? _client;
  List<LibsqlClient> _leitores = const [];
  bool _connected = false;
  String? _urlAtiva;
  String? _tokenAtivo;
  Future<void>? _initEmAndamento;

  /// Motivo da última falha de conexão, em texto curto para o usuário.
  String? ultimoErro;

  /// Incrementa a cada gravação confirmada, para as telas se recarregarem.
  final ValueNotifier<int> dataRevision = ValueNotifier<int>(0);

  bool get isConnected => _connected;
  LibsqlClient? get client => _client;

  /// Conexões disponíveis para leitura em paralelo: a principal e as extras.
  /// Vazia quando não há conexão. As gravações continuam todas na principal,
  /// em ordem — é a ordem que os triggers do inventário cíclico esperam.
  List<LibsqlClient> get clientesLeitura {
    final principal = _client;
    if (!_connected || principal == null) return const [];
    return [principal, ..._leitores];
  }

  Future<bool> temCredenciais() async {
    final prefs = await SharedPreferences.getInstance();
    final url = prefs.getString(keyDbUrl) ?? '';
    final token = prefs.getString(keyDbToken) ?? '';
    return url.isNotEmpty && token.isNotEmpty;
  }

  Future<void> salvarCredenciais(String url, String token) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(keyDbUrl, url.trim());
    await prefs.setString(keyDbToken, token.trim());
    // Força o próximo init a reconectar, em vez de reaproveitar a conexão
    // antiga (que ainda aponta para as credenciais anteriores).
    _urlAtiva = null;
    _tokenAtivo = null;
  }

  Future<(String, String)> lerCredenciais() async {
    final prefs = await SharedPreferences.getInstance();
    return (
      prefs.getString(keyDbUrl) ?? '',
      prefs.getString(keyDbToken) ?? '',
    );
  }

  /// Serializa os inits: se um init antigo ainda roda com credenciais
  /// velhas, o próximo espera e roda em seguida, aplicando as novas.
  Future<void> init() {
    final anterior = _initEmAndamento ?? Future<void>.value();
    final novo = anterior.catchError((_) {}).then<void>((_) => _init());
    _initEmAndamento = novo;
    return novo;
  }

  Future<void> _init() async {
    final (url, token) = await lerCredenciais();

    if (_connected && _client != null && url == _urlAtiva && token == _tokenAtivo) {
      return;
    }

    final antigos = [if (_client != null) _client!, ..._leitores];
    _connected = false;
    _client = null;
    _leitores = const [];
    _urlAtiva = null;
    _tokenAtivo = null;

    for (final antigo in antigos) {
      unawaited(antigo.dispose().catchError((_) {}));
    }

    if (url.isEmpty || token.isEmpty) {
      ultimoErro = 'URL e token do banco não configurados.';
      return;
    }

    try {
      final client = LibsqlClient.remote(url, authToken: token);
      await client.connect().timeout(_timeoutConexao);
      _client = client;
      _leitores = await _abrirLeitores(url, token);
      _connected = true;
      _urlAtiva = url;
      _tokenAtivo = token;
      ultimoErro = null;
    } catch (e) {
      _connected = false;
      _client = null;
      ultimoErro = _descreverErro(e);
    }
  }

  /// Abre as conexões extras de leitura. Se alguma falhar, segue com as que
  /// abriram (ou nenhuma): a lista carrega do mesmo jeito, só mais devagar.
  Future<List<LibsqlClient>> _abrirLeitores(String url, String token) async {
    final abertos = <LibsqlClient>[];
    for (var i = 0; i < _leitoresExtras; i++) {
      try {
        final leitor = LibsqlClient.remote(url, authToken: token);
        await leitor.connect().timeout(_timeoutConexao);
        abertos.add(leitor);
      } catch (_) {
        break;
      }
    }
    return abertos;
  }

  Future<bool> garantirConexao() async {
    if (_connected && _client != null) return true;
    await init();
    return _connected && _client != null;
  }

  /// Testa credenciais sem tocar na conexão ativa — usado pela tela de
  /// configuração, que precisa dizer "deu certo" antes de o usuário sair.
  Future<String?> testarCredenciais(String url, String token) async {
    if (url.trim().isEmpty || token.trim().isEmpty) {
      return 'Preencha a URL e o token.';
    }
    LibsqlClient? client;
    try {
      client = LibsqlClient.remote(url.trim(), authToken: token.trim());
      await client.connect().timeout(_timeoutConexao);
      final stmt = await client.prepare(
        'SELECT count(*) AS n FROM contagem_itens',
      );
      await stmt.query();
      return null;
    } catch (e) {
      return _descreverErro(e);
    } finally {
      if (client != null) {
        unawaited(client.dispose().catchError((_) {}));
      }
    }
  }

  String _descreverErro(Object e) {
    final texto = e.toString();
    if (e is TimeoutException) {
      return 'Tempo esgotado ao falar com o banco — verifique a internet.';
    }
    if (texto.contains('UNAUTHORIZED') || texto.contains('401')) {
      return 'Token recusado pelo Turso. Gere um token novo e reconfigure.';
    }
    if (texto.contains('no such table')) {
      return 'Banco conectado, mas sem a tabela contagem_itens. '
          'Confira se a URL aponta para o banco do dashboard CAMDA.';
    }
    if (texto.contains('SocketException') ||
        texto.contains('Failed host lookup') ||
        texto.contains('Connection refused')) {
      return 'Sem conexão com o banco — verifique a internet e a URL.';
    }
    return texto.length > 160 ? '${texto.substring(0, 160)}…' : texto;
  }
}
