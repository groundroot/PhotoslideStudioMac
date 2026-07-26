(function () {
  const VERTEX_SHADER = `
    attribute vec2 aPosition;
    varying vec2 vUv;

    void main() {
      vUv = vec2((aPosition.x + 1.0) * 0.5, 1.0 - ((aPosition.y + 1.0) * 0.5));
      gl_Position = vec4(aPosition, 0.0, 1.0);
    }
  `;

  const FRAGMENT_SHADERS = {
    crossfade: `
      precision mediump float;
      varying vec2 vUv;
      uniform sampler2D uFrom;
      uniform sampler2D uTo;
      uniform vec2 uFromSize;
      uniform vec2 uToSize;
      uniform vec2 uViewportSize;
      uniform float uProgress;
      uniform float uFitMode;

      vec2 fittedUv(vec2 uv, vec2 sourceSize, float fitMode) {
        if (fitMode > 1.5) {
          return uv;
        }

        vec2 viewport = uViewportSize;
        vec2 scale = viewport / sourceSize;
        float factor = fitMode > 0.5 ? min(scale.x, scale.y) : max(scale.x, scale.y);
        vec2 drawSize = sourceSize * factor;
        vec2 offset = (viewport - drawSize) * 0.5;
        vec2 pixel = uv * viewport;
        return (pixel - offset) / drawSize;
      }

      vec4 sampleTexture(sampler2D tex, vec2 uv, vec2 sourceSize, float fitMode) {
        vec2 mapped = fittedUv(uv, sourceSize, fitMode);
        if (mapped.x < 0.0 || mapped.x > 1.0 || mapped.y < 0.0 || mapped.y > 1.0) {
          return vec4(0.0, 0.0, 0.0, 1.0);
        }
        return texture2D(tex, mapped);
      }

      void main() {
        vec4 fromColor = sampleTexture(uFrom, vUv, uFromSize, uFitMode);
        vec4 toColor = sampleTexture(uTo, vUv, uToSize, uFitMode);
        gl_FragColor = mix(fromColor, toColor, uProgress);
      }
    `,
    directionalSlide: `
      precision mediump float;
      varying vec2 vUv;
      uniform sampler2D uFrom;
      uniform sampler2D uTo;
      uniform vec2 uFromSize;
      uniform vec2 uToSize;
      uniform vec2 uViewportSize;
      uniform vec2 uDirection;
      uniform float uProgress;
      uniform float uFitMode;

      vec2 fittedUv(vec2 uv, vec2 sourceSize, float fitMode) {
        if (fitMode > 1.5) {
          return uv;
        }

        vec2 viewport = uViewportSize;
        vec2 scale = viewport / sourceSize;
        float factor = fitMode > 0.5 ? min(scale.x, scale.y) : max(scale.x, scale.y);
        vec2 drawSize = sourceSize * factor;
        vec2 offset = (viewport - drawSize) * 0.5;
        vec2 pixel = uv * viewport;
        return (pixel - offset) / drawSize;
      }

      vec4 sampleTexture(sampler2D tex, vec2 uv, vec2 sourceSize, float fitMode) {
        vec2 mapped = fittedUv(uv, sourceSize, fitMode);
        if (mapped.x < 0.0 || mapped.x > 1.0 || mapped.y < 0.0 || mapped.y > 1.0) {
          return vec4(0.0, 0.0, 0.0, 1.0);
        }
        return texture2D(tex, mapped);
      }

      void main() {
        vec2 fromUv = vUv + (uDirection * uProgress);
        vec2 toUv = vUv - (uDirection * (1.0 - uProgress));

        vec4 fromColor = sampleTexture(uFrom, fromUv, uFromSize, uFitMode);
        vec4 toColor = sampleTexture(uTo, toUv, uToSize, uFitMode);

        float transitionMask = step(0.0, dot(uDirection, vec2(1.0)) + dot(uDirection, vec2(0.0)));
        gl_FragColor = mix(fromColor, toColor, smoothstep(0.0, 1.0, uProgress));
      }
    `,
    zoomDissolve: `
      precision mediump float;
      varying vec2 vUv;
      uniform sampler2D uFrom;
      uniform sampler2D uTo;
      uniform vec2 uFromSize;
      uniform vec2 uToSize;
      uniform vec2 uViewportSize;
      uniform float uProgress;
      uniform float uFitMode;

      vec2 fittedUv(vec2 uv, vec2 sourceSize, float fitMode) {
        if (fitMode > 1.5) {
          return uv;
        }

        vec2 viewport = uViewportSize;
        vec2 scale = viewport / sourceSize;
        float factor = fitMode > 0.5 ? min(scale.x, scale.y) : max(scale.x, scale.y);
        vec2 drawSize = sourceSize * factor;
        vec2 offset = (viewport - drawSize) * 0.5;
        vec2 pixel = uv * viewport;
        return (pixel - offset) / drawSize;
      }

      vec4 sampleTexture(sampler2D tex, vec2 uv, vec2 sourceSize, float fitMode) {
        vec2 mapped = fittedUv(uv, sourceSize, fitMode);
        if (mapped.x < 0.0 || mapped.x > 1.0 || mapped.y < 0.0 || mapped.y > 1.0) {
          return vec4(0.0, 0.0, 0.0, 1.0);
        }
        return texture2D(tex, mapped);
      }

      void main() {
        vec2 center = vec2(0.5, 0.5);
        float eased = smoothstep(0.0, 1.0, uProgress);
        vec2 fromUv = center + (vUv - center) * mix(1.0, 1.22, eased);
        vec2 toUv = center + (vUv - center) * mix(0.84, 1.0, eased);

        vec4 fromColor = sampleTexture(uFrom, fromUv, uFromSize, uFitMode);
        vec4 toColor = sampleTexture(uTo, toUv, uToSize, uFitMode);

        float noise = fract(sin(dot(vUv * (uViewportSize / 120.0), vec2(12.9898, 78.233))) * 43758.5453);
        float dissolve = smoothstep(noise * 0.28, 1.0 - (0.28 * (1.0 - noise)), eased);
        gl_FragColor = mix(fromColor, toColor, dissolve);
      }
    `
  };

  function compileShader(gl, type, source) {
    const shader = gl.createShader(type);
    gl.shaderSource(shader, source);
    gl.compileShader(shader);
    if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) {
      const error = gl.getShaderInfoLog(shader);
      gl.deleteShader(shader);
      throw new Error(error || "shader-compile-failed");
    }
    return shader;
  }

  function createProgram(gl, fragmentSource) {
    const vertexShader = compileShader(gl, gl.VERTEX_SHADER, VERTEX_SHADER);
    const fragmentShader = compileShader(gl, gl.FRAGMENT_SHADER, fragmentSource);
    const program = gl.createProgram();
    gl.attachShader(program, vertexShader);
    gl.attachShader(program, fragmentShader);
    gl.linkProgram(program);
    gl.deleteShader(vertexShader);
    gl.deleteShader(fragmentShader);

    if (!gl.getProgramParameter(program, gl.LINK_STATUS)) {
      const error = gl.getProgramInfoLog(program);
      gl.deleteProgram(program);
      throw new Error(error || "program-link-failed");
    }

    return program;
  }

  function createTexture(gl, image) {
    const texture = gl.createTexture();
    gl.bindTexture(gl.TEXTURE_2D, texture);
    gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL, 1);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, image);
    gl.bindTexture(gl.TEXTURE_2D, null);
    return texture;
  }

  function effectDescriptor(effect) {
    switch (effect) {
      case "slide-left":
        return { shader: "directionalSlide", direction: [1, 0] };
      case "slide-right":
        return { shader: "directionalSlide", direction: [-1, 0] };
      case "slide-up":
        return { shader: "directionalSlide", direction: [0, -1] };
      case "slide-down":
        return { shader: "directionalSlide", direction: [0, 1] };
      case "zoom-dissolve":
        return { shader: "zoomDissolve", direction: [0, 0] };
      case "crossfade":
      default:
        return { shader: "crossfade", direction: [0, 0] };
    }
  }

  function fitModeValue(fitMode) {
    switch (fitMode) {
      case "fit":
        return 1;
      case "stretch":
        return 2;
      case "fill":
      default:
        return 0;
    }
  }

  window.DreamGPUTransitions = {
    create(canvas) {
      if (!canvas) {
        return {
          isSupported: () => false,
          supportsEffect: () => false,
          cancel() {},
          clear() {},
          transition: async () => false
        };
      }

      const gl = canvas.getContext("webgl", {
        alpha: true,
        antialias: true,
        premultipliedAlpha: false,
        preserveDrawingBuffer: false
      });

      if (!gl) {
        return {
          isSupported: () => false,
          supportsEffect: () => false,
          cancel() {},
          clear() {
            canvas.classList.remove("is-active");
          },
          transition: async () => false
        };
      }

      const programCache = new Map();
      const quadBuffer = gl.createBuffer();
      let transitionToken = 0;

      gl.bindBuffer(gl.ARRAY_BUFFER, quadBuffer);
      gl.bufferData(
        gl.ARRAY_BUFFER,
        new Float32Array([
          -1, -1,
           1, -1,
          -1,  1,
          -1,  1,
           1, -1,
           1,  1
        ]),
        gl.STATIC_DRAW
      );
      gl.bindBuffer(gl.ARRAY_BUFFER, null);

      function resize() {
        const dpr = Math.min(window.devicePixelRatio || 1, 2);
        const width = Math.max(2, Math.round(canvas.clientWidth * dpr));
        const height = Math.max(2, Math.round(canvas.clientHeight * dpr));
        if (canvas.width !== width || canvas.height !== height) {
          canvas.width = width;
          canvas.height = height;
        }
        gl.viewport(0, 0, canvas.width, canvas.height);
      }

      function getProgram(effect) {
        const { shader } = effectDescriptor(effect);
        if (!programCache.has(shader)) {
          programCache.set(shader, createProgram(gl, FRAGMENT_SHADERS[shader]));
        }
        return programCache.get(shader);
      }

      function clear() {
        transitionToken += 1;
        canvas.classList.remove("is-active");
        gl.clearColor(0, 0, 0, 0);
        gl.clear(gl.COLOR_BUFFER_BIT);
      }

      async function transition({ fromImage, toImage, effect, durationMs, fitMode }) {
        if (!(fromImage instanceof HTMLImageElement) || !(toImage instanceof HTMLImageElement)) {
          return false;
        }

        transitionToken += 1;
        const localToken = transitionToken;
        resize();
        canvas.classList.add("is-active");

        const descriptor = effectDescriptor(effect);
        const program = getProgram(effect);
        const fromTexture = createTexture(gl, fromImage);
        const toTexture = createTexture(gl, toImage);

        const positionLocation = gl.getAttribLocation(program, "aPosition");
        const fromLocation = gl.getUniformLocation(program, "uFrom");
        const toLocation = gl.getUniformLocation(program, "uTo");
        const progressLocation = gl.getUniformLocation(program, "uProgress");
        const fromSizeLocation = gl.getUniformLocation(program, "uFromSize");
        const toSizeLocation = gl.getUniformLocation(program, "uToSize");
        const viewportSizeLocation = gl.getUniformLocation(program, "uViewportSize");
        const fitModeLocation = gl.getUniformLocation(program, "uFitMode");
        const directionLocation = gl.getUniformLocation(program, "uDirection");

        return new Promise((resolve) => {
          const startedAt = performance.now();

          function draw(now) {
            if (localToken !== transitionToken) {
              gl.deleteTexture(fromTexture);
              gl.deleteTexture(toTexture);
              clear();
              resolve(false);
              return;
            }

            resize();
            const progress = Math.min(1, (now - startedAt) / Math.max(durationMs, 1));

            gl.useProgram(program);
            gl.bindBuffer(gl.ARRAY_BUFFER, quadBuffer);
            gl.enableVertexAttribArray(positionLocation);
            gl.vertexAttribPointer(positionLocation, 2, gl.FLOAT, false, 0, 0);

            gl.activeTexture(gl.TEXTURE0);
            gl.bindTexture(gl.TEXTURE_2D, fromTexture);
            gl.uniform1i(fromLocation, 0);

            gl.activeTexture(gl.TEXTURE1);
            gl.bindTexture(gl.TEXTURE_2D, toTexture);
            gl.uniform1i(toLocation, 1);

            gl.uniform1f(progressLocation, progress);
            gl.uniform2f(fromSizeLocation, fromImage.naturalWidth || fromImage.width || 1, fromImage.naturalHeight || fromImage.height || 1);
            gl.uniform2f(toSizeLocation, toImage.naturalWidth || toImage.width || 1, toImage.naturalHeight || toImage.height || 1);
            gl.uniform2f(viewportSizeLocation, canvas.width, canvas.height);
            gl.uniform1f(fitModeLocation, fitModeValue(fitMode));
            if (directionLocation) {
              gl.uniform2f(directionLocation, descriptor.direction[0], descriptor.direction[1]);
            }

            gl.clearColor(0, 0, 0, 0);
            gl.clear(gl.COLOR_BUFFER_BIT);
            gl.drawArrays(gl.TRIANGLES, 0, 6);

            if (progress < 1) {
              requestAnimationFrame(draw);
              return;
            }

            gl.deleteTexture(fromTexture);
            gl.deleteTexture(toTexture);
            resolve(true);
          }

          requestAnimationFrame(draw);
        }).finally(() => {
          if (localToken === transitionToken) {
            clear();
          }
        });
      }

      return {
        isSupported() {
          return true;
        },
        supportsEffect(effect) {
          return ["crossfade", "slide-left", "slide-right", "slide-up", "slide-down", "zoom-dissolve"].includes(effect);
        },
        cancel() {
          clear();
        },
        clear,
        transition
      };
    }
  };
})();
