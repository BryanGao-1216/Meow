# Model directory

The LLM weights are **not** committed to this repository (~907 MB). Download them
into this folder before packaging the app.

## Default model

Meow is built and tuned against
[`mlx-community/MiniCPM5-1B-OptiQ-4bit`](https://huggingface.co/mlx-community/MiniCPM5-1B-OptiQ-4bit):

```bash
cd model
for f in config.json generation_config.json model.safetensors \
         model.safetensors.index.json tokenizer.json tokenizer_config.json \
         chat_template.jinja; do
  curl -L -O "https://huggingface.co/mlx-community/MiniCPM5-1B-OptiQ-4bit/resolve/main/$f"
done
```

(or use `huggingface-cli download mlx-community/MiniCPM5-1B-OptiQ-4bit --local-dir .`)

The packaging script copies everything here into
`Meow.app/Contents/Resources/model/`.

## Using a different MLX model

See [docs/BUILDING.md](../docs/BUILDING.md#using-a-different-model) — any
llama-family MLX model with a ChatML-style chat template works with minor or no
code changes.
