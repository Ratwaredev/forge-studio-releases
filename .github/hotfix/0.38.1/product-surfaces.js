(() => {
  const PRODUCTS = {
    game: { label: "Forge Game", sections: { all: ["project","approved","modules","templates","vfx","spells","ships","vault"], "2d": ["project","approved","modules"], "3d": ["project","approved","ships","vault"], vfx: ["vfx","spells","modules"], shaders: ["vfx","modules","approved"], assets: ["project","approved","ships","vault"], gameplay: ["approved","modules"], ui: ["approved","modules"], templates: ["templates"] } },
    web: { label: "Forge Web", sections: { all: ["project","approved","modules","templates","vault"], landing: ["templates","approved","project"], apps: ["templates","approved","project"], components: ["approved","modules","project"], web3d: ["templates","vault","approved","project"], motion: ["approved","modules","templates"], templates: ["templates"], seo: ["modules","approved"], performance: ["vault","modules","approved"], deploy: ["modules","approved"] } },
    tool: { label: "Forge Tools", sections: { all: ["project","approved","modules","templates"], automation: ["project","approved","modules","templates"], cli: ["project","approved","modules","templates"], templates: ["templates"] } }
  };
  const LABELS = { game: { "2d":"2D", "3d":"3D", vfx:"VFX", shaders:"Shaders", assets:"Assets", gameplay:"Gameplay", ui:"UI", templates:"Templates" }, web: { landing:"Landing Pages", apps:"Web Apps", components:"Components", web3d:"3D / WebGL", motion:"Motion", templates:"Templates", seo:"SEO", performance:"Performance", deploy:"Deploy" }, tool: { automation:"Automation", cli:"CLI / Services", templates:"Templates" } };
  const TYPE = { "project-assets":"project", candidates:"project", approved:"approved", modules:"modules", vfx:"vfx", ships:"ships", vault:"vault", spells:"spells", templates:"templates" };
  const CATEGORY = { game:"game", app:"web", tool:"tool" };
  const KIND = { godot:"game", blender:"game", next:"web", vite:"web", static:"web", node:"tool", python:"tool", rust:"tool" };
  const params = new URLSearchParams(location.search);
  let product = PRODUCTS[params.get("product")] ? params.get("product") : (PRODUCTS[localStorage.getItem("forge-product-surface")] ? localStorage.getItem("forge-product-surface") : "web");
  let section = params.get("section") || "all";

  const context = () => { try { return window.__forgeProductContext?.() || {}; } catch { return {}; } };
  const infer = (value = context()) => CATEGORY[value?.project?.category] || KIND[value?.version?.analysis?.kind] || product;
  const effective = (value = context()) => value?.project ? infer(value) : product;
  const families = (value = context()) => new Set((PRODUCTS[effective(value)] || PRODUCTS.web).sections[section] || (PRODUCTS[effective(value)] || PRODUCTS.web).sections.all);
  const familyOf = (type) => TYPE[type] || type;
  const filterLocalItems = (items, value = context()) => { const allowed = families(value); return (items || []).filter((item) => allowed.has(familyOf(item.type))); };
  const filterTemplateItems = (items) => {
    let rows = (items || []).filter((item) => (item.raw?.product || "web") === product);
    if (product === "web" && ["landing","apps","web3d"].includes(section)) rows = rows.filter((item) => item.raw?.section === section);
    return rows;
  };

  function updateUrl() {
    if (!location.pathname.endsWith("library.html")) return;
    const url = new URL(location.href);
    url.searchParams.set("product", product);
    section === "all" ? url.searchParams.delete("section") : url.searchParams.set("section", section);
    history.replaceState(null, "", url);
  }

  function setProduct(next, syncFilter = true) {
    if (!PRODUCTS[next]) return;
    product = next;
    if (!(section in PRODUCTS[next].sections)) section = "all";
    localStorage.setItem("forge-product-surface", next);
    const category = next === "web" ? "app" : next;
    const categoryInput = document.querySelector(`input[name="category"][value="${category}"]`);
    if (categoryInput) categoryInput.checked = true;
    if (syncFilter) document.querySelector(`[data-project-filter="${category}"]`)?.click();
    updateUrl(); render();
    window.dispatchEvent(new CustomEvent("forge:product-changed"));
  }

  function setSection(next) {
    if (!(next in PRODUCTS[product].sections)) return;
    section = next; updateUrl(); render();
    document.querySelector('[data-library-app-tab="all"]')?.click();
    document.querySelector('[data-library-tab="all"]')?.click();
    if (["landing","apps","templates"].includes(next)) document.querySelector('[data-online-library-tab="templates"]')?.click();
    window.dispatchEvent(new CustomEvent("forge:product-section-changed"));
  }

  function ensureUi() {
    const header = document.querySelector(".app-header, .forge-library-header");
    if (header && !document.getElementById("forgeProductSwitcher")) {
      const node = document.createElement("div"); node.id = "forgeProductSwitcher"; node.className = "forge-product-switcher";
      node.innerHTML = Object.keys(PRODUCTS).map((id) => `<button type="button" data-forge-product="${id}">${id === "tool" ? "Tools" : id[0].toUpperCase()+id.slice(1)}</button>`).join("");
      header.insertBefore(node, header.querySelector(".global-search, .forge-library-header-spacer"));
    }
    const heading = document.querySelector(".forge-library-heading, .library-heading");
    if (heading && !document.getElementById("forgeProductSections")) {
      const nav = document.createElement("nav"); nav.id = "forgeProductSections"; nav.className = "forge-product-sections"; heading.after(nav);
    }
  }

  function render() {
    ensureUi();
    const id = effective();
    document.body.dataset.forgeProduct = id;
    document.body.dataset.forgeSection = section;
    document.querySelectorAll("[data-forge-product]").forEach((button) => button.classList.toggle("active", button.dataset.forgeProduct === product));
    const nav = document.getElementById("forgeProductSections");
    if (nav) nav.innerHTML = `<button type="button" data-forge-section="all" class="${section === "all" ? "active" : ""}">Todo</button>` + Object.keys(PRODUCTS[product].sections).filter((key) => key !== "all").map((key) => `<button type="button" data-forge-section="${key}" class="${section === key ? "active" : ""}">${LABELS[product][key] || key}</button>`).join("");
    const allowed = families();
    document.querySelectorAll("[data-library-tab],[data-library-app-tab]").forEach((button) => {
      const type = button.dataset.libraryTab || button.dataset.libraryAppTab;
      button.classList.toggle("product-hidden", type !== "all" && !allowed.has(familyOf(type)));
    });
    document.querySelectorAll("[data-online-library-tab]").forEach((button) => {
      const mode = button.dataset.onlineLibraryTab;
      button.classList.toggle("product-hidden", mode === "templates" ? !allowed.has("templates") : mode === "spells" ? !allowed.has("spells") : id !== "game");
    });
    const select = document.getElementById("libraryUnifiedType");
    if (select) [...select.options].forEach((option) => { if (option.value !== "all") option.hidden = !allowed.has(familyOf(option.value)); });
    const copy = document.querySelector(".forge-library-heading p");
    if (copy) copy.textContent = id === "game" ? "2D, 3D, VFX, shaders, assets y templates de game dev." : id === "web" ? "Landing pages, apps, components, WebGL, motion, performance y deploy." : "Automation, CLI/services y templates.";
  }

  document.addEventListener("click", (event) => {
    const p = event.target.closest("[data-forge-product]"); if (p) return setProduct(p.dataset.forgeProduct);
    const s = event.target.closest("[data-forge-section]"); if (s) return setSection(s.dataset.forgeSection);
  });
  window.addEventListener("forge:context-changed", render);
  window.addEventListener("DOMContentLoaded", () => { render(); setInterval(render, 1000); });

  window.ForgeProductSurface = { products:PRODUCTS, infer, effectiveProduct:effective, filterLocalItems, filterTemplateItems, resourceAllowed:(type,value)=>families(value).has(familyOf(type)), setProduct, setSection, get product(){return product;}, get section(){return section;} };
})();
