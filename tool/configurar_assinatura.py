#!/usr/bin/env python3
"""Configura a assinatura de release do APK a partir dos secrets do CI.

Roda DEPOIS do `flutter create` que gera a pasta `android/` (ver build.yml) e
antes do `flutter build apk`. Faz três coisas:

1. decodifica o keystore de KEYSTORE_BASE64 para android/app/upload-keystore.jks;
2. escreve android/key.properties com alias e senhas;
3. remenda android/app/build.gradle.kts para usar esse keystore no release.

Por que remendar em vez de versionar o build.gradle.kts pronto: a pasta
`android/` inteira é gerada pelo CI a cada build (para não versionar binários
como o gradle-wrapper.jar), então não há arquivo nosso para editar — o arquivo
só existe depois do scaffold.

Sem os secrets configurados o script NÃO falha: avisa alto e sai, deixando o
build seguir com a chave de debug do Flutter. Assim quem clonar o repositório
continua conseguindo gerar APK, e o aviso aparece no log e no corpo da release.

Saída para o GitHub Actions (via $GITHUB_OUTPUT): `assinado=true|false`.
"""

import base64
import binascii
import os
import re
import sys
from pathlib import Path

RAIZ = Path(__file__).resolve().parent.parent
GRADLE = RAIZ / 'android' / 'app' / 'build.gradle.kts'
KEYSTORE = RAIZ / 'android' / 'app' / 'upload-keystore.jks'
PROPRIEDADES = RAIZ / 'android' / 'key.properties'

# Carregamento do key.properties. Em Kotlin DSL os imports têm de ficar no topo
# absoluto do arquivo, antes do bloco plugins.
CABECALHO = '''import java.io.FileInputStream
import java.util.Properties

// Credenciais de assinatura, geradas pelo CI a partir dos secrets do
// repositório (ver tool/configurar_assinatura.py). O arquivo não existe em
// clone limpo — daí o teste de existência.
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystorePropertiesFile.inputStream().use { keystoreProperties.load(it) }
}

'''

BLOCO_ASSINATURA = '''    signingConfigs {
        create("release") {
            keyAlias = keystoreProperties["keyAlias"] as String
            keyPassword = keystoreProperties["keyPassword"] as String
            storeFile = file(keystoreProperties["storeFile"] as String)
            storePassword = keystoreProperties["storePassword"] as String
        }
    }

'''


def aviso(mensagem: str) -> None:
    print(f'::warning::{mensagem}')


def registrar_saida(assinado: bool) -> None:
    caminho = os.environ.get('GITHUB_OUTPUT')
    if caminho:
        with open(caminho, 'a', encoding='utf-8') as saida:
            saida.write(f'assinado={"true" if assinado else "false"}\n')


def main() -> int:
    b64 = os.environ.get('KEYSTORE_BASE64', '').strip()
    alias = os.environ.get('KEY_ALIAS', '').strip()
    senha_chave = os.environ.get('KEY_PASSWORD', '')
    senha_store = os.environ.get('STORE_PASSWORD', '')

    faltando = [
        nome
        for nome, valor in (
            ('KEYSTORE_BASE64', b64),
            ('KEY_ALIAS', alias),
            ('KEY_PASSWORD', senha_chave),
            ('STORE_PASSWORD', senha_store),
        )
        if not valor
    ]
    if faltando:
        aviso(
            'Secrets de assinatura ausentes (' + ', '.join(faltando) + '). '
            'O APK sairá assinado com a chave de DEBUG: a assinatura muda a '
            'cada build e atualizar por cima dá "App não foi instalado". '
            'Veja o README para configurar.'
        )
        registrar_saida(False)
        return 0

    if not GRADLE.exists():
        print(f'ERRO: {GRADLE} não existe — rode depois do flutter create.',
              file=sys.stderr)
        return 1

    # 1. Keystore. Um base64 quebrado (copiado com quebras de linha, por
    #    exemplo) tem de falhar aqui, alto, e não virar um .jks inválido que
    #    só estoura lá na frente com erro obscuro do gradle.
    try:
        binario = base64.b64decode(b64, validate=True)
    except (binascii.Error, ValueError) as erro:
        print(f'ERRO: KEYSTORE_BASE64 não é base64 válido ({erro}). '
              'Gere de novo com: base64 -w 0 upload-keystore.jks',
              file=sys.stderr)
        return 1

    # Todo keystore JKS começa com a magic 0xFEEDFEED; PKCS#12 é um DER que
    # começa com 0x30. Qualquer outra coisa é conteúdo errado no secret.
    if not (binario.startswith(b'\xfe\xed\xfe\xed') or binario.startswith(b'\x30')):
        print('ERRO: o conteúdo de KEYSTORE_BASE64 não parece um keystore '
              '(nem JKS nem PKCS#12).', file=sys.stderr)
        return 1

    KEYSTORE.write_bytes(binario)

    # 2. key.properties. Caminho absoluto de propósito: `file()` no Kotlin DSL
    #    resolve relativo ao módulo app, e um caminho relativo aqui já foi
    #    fonte de confusão em projetos Flutter.
    PROPRIEDADES.write_text(
        f'storeFile={KEYSTORE}\n'
        f'storePassword={senha_store}\n'
        f'keyAlias={alias}\n'
        f'keyPassword={senha_chave}\n',
        encoding='utf-8',
    )

    # 3. Remendo do build.gradle.kts.
    texto = GRADLE.read_text(encoding='utf-8')

    # Guarda de idempotência: procura a DECLARAÇÃO do bloco (`signingConfigs {`),
    # não a substring solta. O scaffold padrão já contém
    # `signingConfigs.getByName("debug")`, então um teste por substring casa
    # sempre e o script sai sem remendar nada — dizendo que deu certo.
    if 'signingConfigs {' in texto:
        print('build.gradle.kts já tem o bloco signingConfigs — nada a remendar.')
        registrar_saida(True)
        return 0

    texto = CABECALHO + texto

    # O bloco de assinatura entra imediatamente antes de buildTypes, dentro de
    # android { }. Ancorar em "buildTypes {" com a indentação de quatro espaços
    # é o que garante que se está dentro do bloco android, e não em outro.
    if '\n    buildTypes {\n' not in texto:
        print('ERRO: não achei o bloco buildTypes em build.gradle.kts. '
              'O scaffold do Flutter mudou de formato — reveja este script.',
              file=sys.stderr)
        return 1
    texto = texto.replace('\n    buildTypes {\n',
                          '\n' + BLOCO_ASSINATURA + '    buildTypes {\n', 1)

    # Troca a chave de debug pela de release. Sem esta linha o build sai
    # verdinho e assinado com a chave errada — exatamente o problema que este
    # script existe para resolver —, então a ausência do padrão é erro.
    padrao = re.compile(r'signingConfig\s*=\s*signingConfigs\.getByName\("debug"\)')
    texto, trocas = padrao.subn(
        'signingConfig = signingConfigs.getByName("release")', texto)
    if trocas != 1:
        print(f'ERRO: esperava 1 signingConfig de debug para trocar, achei '
              f'{trocas}. Reveja o scaffold do Flutter.', file=sys.stderr)
        return 1

    GRADLE.write_text(texto, encoding='utf-8')
    print(f'Assinatura de release configurada (alias: {alias}).')
    registrar_saida(True)
    return 0


if __name__ == '__main__':
    sys.exit(main())
