import { defineConfig } from "blume";

export default defineConfig({
  title: "Capd fork",
  description: "Capture, search and optionally sync a local library on Mac and iPhone.",
  logo: { image: "/logo.svg", text: "Capd" },
  content: {
    root: "content",
  },
  github: {
    owner: "EzraCerpac",
    repo: "capd",
    dir: "docs",
  },
});
