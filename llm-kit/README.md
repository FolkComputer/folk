# LLM Kit

This project allows you to call and interact with LLM toolchains inside
of Folk. A simple example, on any program:

```tcl
When the Gemini responder is /gemini/ {
    fn gemini

    # ———— Now, for the fun part: ————
    Wish $this is labelled [gemini "How's the weather in McCarren Park rn?"]
}
```

[Folk Computer](https://github.com/FolkComputer/folk) is a tangible
computing operating system. This project enables anyone running `folk2`
to interact with LLMs via a simple function call.

## Setup

1. Put your Gemini API key (get one at https://aistudio.google.com) in
   `~/folk-data/llm/gemini.json`:

   ```json
   { "api_key": "YOUR-API-KEY" }
   ```

   Optionally add `"model": "gemini-2.5-pro"` to override the default
   model (`gemini-2.5-flash`).

2. Install the kit so Folk loads it at boot:

   ```sh
   mkdir -p ~/folk-data/local-program
   ln -s "$(pwd)/llm-kit/llm-kit.folk" ~/folk-data/local-program/
   ```

3. Print a program with the example above and put it on the table.

## How it works

`llm-kit.folk` defines a `gemini` function that reads your key from
`~/folk-data/llm/gemini.json`, POSTs the prompt to the Gemini API with
`curl`, and returns the response text. It shares that function with
every other program on the table the usual Folk way:

```tcl
Claim the Gemini responder is [fn gemini]
```

Responses are cached per prompt, so reloading a program doesn't re-ask
its question.

## Adding other providers

Copy the `gemini` fn, point it at your provider's HTTP API, read its
key from `~/folk-data/llm/<provider>.json`, and claim it:

```tcl
Claim the Claude responder is [fn claude]
```
