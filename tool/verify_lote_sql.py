"""Roda os lotes de gravação do app num SQLite real temporário.

    python3 tool/verify_lote_sql.py

Confere: grava tudo, reenviar o mesmo lote não muda nada (idempotência pelo
UUID), as guardas de conflito abortam o lote inteiro com o marcador certo e o
lote do esquema antigo roda sem as colunas de migração.
"""
import json
import pathlib
import sqlite3
import subprocess

RAIZ = pathlib.Path(__file__).resolve().parent.parent
lotes = json.loads(subprocess.check_output(
    ['dart', 'run', 'tool/gerar_lotes.dart'], cwd=RAIZ, text=True))

ESQUEMA = """
CREATE TABLE contagem_itens (id INTEGER PRIMARY KEY, codigo TEXT, status TEXT,
  motivo TEXT, qtd_divergencia INTEGER, confirmado_em TEXT);
CREATE TABLE estoque_mestre (codigo TEXT, status TEXT, qtd_sistema INTEGER,
  qtd_fisica INTEGER, diferenca INTEGER, nota TEXT, observacoes TEXT,
  ultima_contagem TEXT);
CREATE TABLE divergencias (id INTEGER PRIMARY KEY, codigo TEXT, produto TEXT,
  categoria TEXT, delta INTEGER, status TEXT, cooperado TEXT, criado_em TEXT);
CREATE TABLE historico_divergencias (id INTEGER PRIMARY KEY, codigo TEXT,
  produto TEXT, categoria TEXT, cooperado TEXT, delta INTEGER, status TEXT,
  criado_em TEXT);
INSERT INTO contagem_itens (id, codigo, status) VALUES
  (1, '222534', 'pendente'), (2, 'US222534', 'pendente'),
  (3, '222534', 'pendente'), (4, '222534', 'pendente');
INSERT INTO estoque_mestre VALUES
  ('222534', 'falta', 11, 9, -2, 'x', '', NULL),
  ('US222534', 'ok', 73, 73, 0, '', '', NULL);
INSERT INTO divergencias (codigo, delta, status) VALUES ('222534', -2, 'falta');
"""


def banco(esquema=ESQUEMA):
    db = sqlite3.connect(':memory:', isolation_level=None)
    db.executescript(esquema)
    return db


def foto(db):
    return [db.execute(f'SELECT * FROM {t} ORDER BY 1').fetchall()
            for t in ('contagem_itens', 'estoque_mestre', 'divergencias',
                      'historico_divergencias')]


def falha(db, texto):
    try:
        db.executescript(texto)
    except sqlite3.Error as e:
        if db.in_transaction:
            db.execute('ROLLBACK')
        return str(e)
    return None


# 1. OK: grava, e o reenvio não muda nada.
db = banco()
assert falha(db, lotes['certa']) is None
depois = foto(db)
assert [r[2] for r in depois[0][:2]] == ['certa', 'certa'], depois[0]
assert depois[0][0][5] == '2026-11-03 12:00:00', depois[0][0]
assert depois[1][0][1:4] == ('ok', 11, 11), depois[1][0]
assert depois[2] == [], 'divergência antiga devia ter saído'
assert falha(db, lotes['certa']) is None
assert foto(db) == depois, 'reenvio mudou o banco'
print('ok  OK grava e é idempotente')

# 2. Divergência: uma linha em cada tabela, e o reenvio não duplica.
assert falha(db, lotes['divergencia']) is None
assert falha(db, lotes['divergencia']) is None
f = foto(db)
assert f[0][2][2:4] == ('divergencia', 'JOAO'), f[0][2]
assert len(f[2]) == 1 and f[2][0][4] == -3, f[2]
assert len(f[3]) == 1, f[3]
assert f[1][0][3] == 8 and f[1][0][4] == -3, f[1][0]
print('ok  divergência grava uma vez só')

# 3. Outro UUID sobre item já conferido: conflito, nada muda.
antes = foto(db)
erro = falha(db, lotes['ja_conferido'])
assert erro and 'CONTAGEM_CONFLITO:ja_conferido' in erro, erro
assert foto(db) == antes
print('ok  ja_conferido aborta o lote inteiro')

# 4. Lista trocada no dashboard.
erro = falha(db, lotes['lista_trocada'])
assert erro and 'CONTAGEM_CONFLITO:lista_trocada' in erro, erro
assert foto(db) == antes
print('ok  lista_trocada aborta o lote inteiro')

# 5. Esquema antigo, sem as colunas de migração.
velho = ESQUEMA.replace(', confirmado_em TEXT', '').replace(
    ' observacoes TEXT,\n', '\n').replace("'x', '', NULL", "'x', NULL").replace(
    "'', '', NULL", "'', NULL")
db = banco(velho)
assert falha(db, lotes['antigo']) is None
assert db.execute('SELECT status FROM contagem_itens WHERE id = 4').fetchone() \
    == ('certa',)
print('ok  esquema antigo grava sem confirmado_em')
print('TUDO CERTO')
