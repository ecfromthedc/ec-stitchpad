export default {
  async fetch(request) {
    const destination = new URL(request.url);
    destination.hostname = "ec-pasture.agentsworld.org";

    const wantsHtml = (request.headers.get("accept") || "").includes("text/html");
    if ((request.method === "GET" || request.method === "HEAD") && (destination.pathname === "/" || wantsHtml)) {
      return Response.redirect(destination.toString(), 308);
    }

    // Preserve legacy CLI, bridge, API, and WebSocket traffic while browsers
    // move to the Pasture URL.
    return fetch(new Request(destination, request));
  },
};
