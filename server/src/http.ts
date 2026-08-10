export function parseJSONBody(body: Buffer): unknown {
  return body.length === 0 ? {} : JSON.parse(body.toString("utf8"));
}
