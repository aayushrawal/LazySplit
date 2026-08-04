import "fastify";
declare module "fastify" {
  interface FastifyRequest {
    userID: string;
    rawBody?: Buffer;
  }
}
