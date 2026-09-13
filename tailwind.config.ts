import type { Config } from "tailwindcss";

const config: Config = {
  content: [
    "./src/pages/**/*.{js,ts,jsx,tsx,mdx}",
    "./src/components/**/*.{js,ts,jsx,tsx,mdx}",
    "./src/app/**/*.{js,ts,jsx,tsx,mdx}",
  ],
  theme: {
    extend: {
      colors: {
        background: "var(--background)",
        foreground: "var(--foreground)",
        surface: {
          DEFAULT: "var(--surface)",
          secondary: "var(--surface-secondary)",
          tertiary: "var(--surface-tertiary)",
        },
        brand: {
          50: "#EFF4FC",
          100: "#DBE6F8",
          200: "#BBD1F2",
          300: "#8EB4E8",
          400: "#5B92DC",
          500: "#3772CE",
          600: "#2256B4",
          700: "#1A4493",
          800: "#173A79",
          900: "#0F2D6B", // Deep New Holland Royal Navy Accent
          950: "#0A1D46",
        },
        status: {
          success: "#10B981",
          warning: "#F59E0B",
          danger: "#EF4444",
          info: "#3B82F6",
        }
      },
      borderRadius: {
        "2xl": "1rem",
        "3xl": "1.25rem",
      },
      boxShadow: {
        subtle: "0 1px 3px 0 rgba(0, 0, 0, 0.04), 0 1px 2px -1px rgba(0, 0, 0, 0.02)",
        card: "0 2px 8px -2px rgba(0, 0, 0, 0.05), 0 1px 4px -1px rgba(0, 0, 0, 0.02)",
        hover: "0 8px 24px -4px rgba(15, 45, 107, 0.08), 0 2px 6px -1px rgba(0, 0, 0, 0.04)",
      },
      fontFamily: {
        sans: ["var(--font-inter)", "system-ui", "-apple-system", "sans-serif"],
      }
    },
  },
  plugins: [],
};
export default config;
