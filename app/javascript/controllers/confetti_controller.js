import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = {
    colors: { type: Array, default: ["#3b82f6", "#22c55e", "#f59e0b", "#ef4444", "#a855f7"] },
    duration: { type: Number, default: 2200 },
    count: { type: Number, default: 140 }
  }

  connect() {
    this.#start()
  }

  disconnect() {
    this.#teardown()
  }

  #start() {
    this.canvas = document.createElement("canvas")
    this.canvas.style.position = "fixed"
    this.canvas.style.inset = "0"
    this.canvas.style.width = "100vw"
    this.canvas.style.height = "100vh"
    this.canvas.style.pointerEvents = "none"
    this.canvas.style.zIndex = "90"
    document.body.appendChild(this.canvas)

    this.ctx = this.canvas.getContext("2d")
    this.#resize()
    this.onResize = () => this.#resize()
    window.addEventListener("resize", this.onResize)

    this.startAt = performance.now()
    this.pieces = Array.from({ length: this.countValue }, () => this.#piece())
    this.raf = requestAnimationFrame((t) => this.#frame(t))
  }

  #frame(now) {
    const elapsed = now - this.startAt
    if (elapsed > this.durationValue) {
      this.#teardown()
      return
    }

    this.ctx.clearRect(0, 0, this.canvas.width, this.canvas.height)
    this.pieces.forEach((p) => {
      p.x += p.vx
      p.y += p.vy
      p.vy += 0.02
      p.rotation += p.spin

      this.ctx.save()
      this.ctx.translate(p.x, p.y)
      this.ctx.rotate(p.rotation)
      this.ctx.fillStyle = p.color
      this.ctx.fillRect(-p.size / 2, -p.size / 2, p.size, p.size)
      this.ctx.restore()
    })

    this.raf = requestAnimationFrame((t) => this.#frame(t))
  }

  #piece() {
    const spread = this.canvas.width * 0.8
    const minX = (this.canvas.width - spread) / 2
    return {
      x: minX + Math.random() * spread,
      y: -20 - Math.random() * 120,
      vx: (Math.random() - 0.5) * 3,
      vy: 1.5 + Math.random() * 2.5,
      size: 5 + Math.random() * 6,
      color: this.colorsValue[Math.floor(Math.random() * this.colorsValue.length)],
      rotation: Math.random() * Math.PI,
      spin: (Math.random() - 0.5) * 0.2
    }
  }

  #resize() {
    this.canvas.width = window.innerWidth
    this.canvas.height = window.innerHeight
  }

  #teardown() {
    if (this.raf) cancelAnimationFrame(this.raf)
    this.raf = null
    if (this.onResize) window.removeEventListener("resize", this.onResize)
    this.onResize = null
    this.canvas?.remove()
    this.canvas = null
    this.ctx = null
    this.pieces = []
  }
}
