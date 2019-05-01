# Qiita:Team to esa.io

## How to use

### 準備

`.env.skeleton` を元に必要な token やファイルを用意する。

#### USERS\_MAP\_PATH

以下のようなリストを YAML で作成する。

```yaml
qiita_id1: esa_screen_name1
qiita_id2: esa_screen_name2
qiita_id3: esa_screen_name3
```

#### QIITA\_EXPORT\_FILE\_PATH

Qiita:Team 記事のエクスポート結果を JSON ファイルで配置する。

### 補足: direnv を利用する場合

[direnv](https://github.com/direnv/direnv)

```
$ echo 'dotenv ./.env' > .envrc
$ cp .env.skeleton .env
```
