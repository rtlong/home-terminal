/** @type {import('tailwindcss').Config} */
module.exports = {
  // Scan all Gleam source files for class names.
  // The scanner is a simple string extractor, no Gleam parsing needed.
  content: ["./src/**/*.gleam"],

  // Dark mode is toggled by the `dark` class on <body>.
  darkMode: "class",

  theme: {
    extend: {},
  },

  plugins: [],
};
