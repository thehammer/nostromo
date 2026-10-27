import anthropic

client = anthropic.Anthropic()


def summarize(entries: list[str]) -> str:
    reply = client.messages.create(
        model="claude-sonnet-4-5",
        max_tokens=400,
        messages=[{"role": "user", "content": "\n".join(entries)}],
    )
    return reply.content[0].text
