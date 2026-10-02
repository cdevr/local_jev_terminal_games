# Local games with decision models: local_jev_terminal_games
Use JEV type model to play a terminal game with directions (up-down, left-right)

## How to use

Here’s a quick local setup:

### Build the server image

This rebuilds llama.cpp and makes it's standard Docker layout available as llama-decision:server to run and serve decision models.

Note: is only needed because this requires the latest release and the Docker image is not fully up to date yet. This should no longer be necessary next week or so.

```
docker build --pull --target server -f .devops/cpu.Dockerfile -t llama-decision:server 'https://github.com/ggml-org/llama.cpp.git#master'
```

### Run the model server:

This runs the model "ggml-org/Kev-4B-GGUF:Q4_K_M", a Qwen3.5 4B based model. Other options:

* ggml-org/Julia-1-GGUF (tiny fast model)
* ggml-org/Laya-GGUF
* ggml-org/Kev-4B-GGUF
* ggml-org/lev-GGUF
* ggml-org/OpenJev-GGUF

```
docker run --rm -it -p 8001:8080 -v llama-hf-cache:/root/.cache/huggingface llama-decision:server -hf ggml-org/Kev-4B-GGUF:Q4_K_M --port 8080
```

### Give it a try

Note: needs a second terminal so the server keeps serving.

```
curl localhost:8001/v1/systemone -H 'Content-Type: application/json' -d '{
"state": "llama.cpp now supports decision models!",
"questions": {
"sentiment": {
"type": "choice",
"instructions": "Is this good or bad?",
"criteria": {
"good": "positive or beneficial",
"bad": "negative or harmful"
}}}}'; echo
```

## Now have the model run 2048

Wrote a script to use unholy tmux-magic and hacks to play a terminal game. I know this is a huge hack, but here you go. Also, it's kind of the point of this repo.

```
./2048_decision.sh
```

Yeah, open models don't do super-well on this. Also I know this doesn't follow a lot of conventions and disclosure: AI was used in making both this file and the scripts (I'm only including the 2048 script since the tetris script really screws up)