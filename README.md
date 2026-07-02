# big_runpod_boss

One-command bootstrap for RunPod GPU pods that installs and launches
**AUTOMATIC1111**, **ComfyUI** and **File Browser** on a single pod, with the
correct CUDA / PyTorch stack auto-selected for the detected GPU.

*[Русская версия ниже ↓](#big_runpod_boss-ru)*

---

## What it does

A GPU-aware dispatcher (`start_combined.sh`) detects the pod's GPU and runs the
matching combined install script. On first boot it installs everything; on pod
restart it detects the existing install and jumps straight to starting services.

### Repository files

| File | Role |
|------|------|
| `start_combined.sh` | Entry point. Detects the GPU and downloads + runs the right combined script. |
| `RTX5090_combined.sh` | Install/run stack for **Blackwell** GPUs (RTX 5090, 50-series, RTX PRO, B-series). |
| `RTX4090_combined.sh` | Install/run stack for **Ada** (RTX 4090, L40/L4) and **Legacy** (H100/A100/3090…). |

### GPU profile → script → stack

| Profile | Matched GPUs | Script | Base image | PyTorch |
|---------|--------------|--------|------------|---------|
| `blackwell` | RTX 5090/5080/5070…, RTX PRO, B200/B300 | `RTX5090_combined.sh` | `runpod/pytorch:2.8.0-py3.11-cuda12.8.1-cudnn-devel-ubuntu22.04` | `2.8.0+cu128` |
| `ada` | RTX 4090/4080/4070…, L40/L40S/L4 | `RTX4090_combined.sh` | `runpod/pytorch:2.4.0-py3.11-cuda12.4.1-devel-ubuntu22.04` | `2.4.0+cu124` |
| `legacy` | H200/H100/A100/A6000, RTX 3090/2080… | `RTX4090_combined.sh` | `runpod/pytorch:2.4.0-py3.11-cuda12.4.1-devel-ubuntu22.04` | `2.4.0+cu124` |

## Usage

Set this as the RunPod **Container Start Command** (must use `bash -c`):

```bash
bash -c 'cd /workspace && wget -q https://raw.githubusercontent.com/IhorBr-git/big_runpod_boss/refs/heads/test/start_combined.sh -O start_combined.sh && chmod +x start_combined.sh && ./start_combined.sh'
```

Pick a pod template whose base image matches your GPU profile (see table above).
The dispatcher does the rest.

## Services & ports

| Service | Port | Notes |
|---------|------|-------|
| AUTOMATIC1111 WebUI | `3000` | args: `--opt-sdp-attention --no-half-vae --api --theme=dark` |
| ComfyUI | `8188` | launched via generated `run_gpu.sh` (`--listen --enable-cors-header '*'`) |
| File Browser | `8080` | default login `admin` / `adminadmin11` |
| RunPod handler | — | `/start.sh` (SSH, Jupyter Lab, nginx) |

## Behavior on restart

Both apps live under `/workspace` (persistent network volume). If
`/workspace/stable-diffusion-webui` **and** `/workspace/ComfyUI` already exist,
installation is skipped and only `start_services` runs. Custom nodes and models
persist across restarts.

## Shared models

All model files are consolidated into `/workspace/models` and symlinked into both
A1111 and ComfyUI so a single copy is shared (checkpoints, loras, vae, controlnet,
embeddings, …).

## Environment overrides

| Variable | Effect |
|----------|--------|
| `GPU_PROFILE=blackwell\|ada\|legacy` | Skip auto-detection, force a profile. |
| `REPO_BASE=<url>` | Change the script download base URL (default: `test` branch). |
| `FORCE_FULL_INSTALL=1` | Force a full reinstall even if `/workspace` already has the apps. |

## Files generated on the pod (not in this repo)

`run_gpu.sh`, `webui-user.sh`, `a1111-pip-constraints.txt`,
`extensions/vram-guard/` (Unload/Load VRAM buttons for A1111),
`.filebrowser.db`.

## Notes

- The combined scripts also **self-heal the ComfyUI PyTorch stack** (cuDNN,
  torch/torchvision ABI mismatches) on restart.
- **Custom ComfyUI nodes are not defined by these scripts** — they are installed
  manually via ComfyUI-Manager and live in `/workspace/ComfyUI/custom_nodes`.
  Heavy or broken nodes there are the usual cause of slow ComfyUI startup.

---
<a name="big_runpod_boss-ru"></a>

# big_runpod_boss (RU)

Bootstrap «в одну команду» для GPU-подов RunPod: ставит и запускает
**AUTOMATIC1111**, **ComfyUI** и **File Browser** на одном поде, автоматически
подбирая правильный стек CUDA / PyTorch под обнаруженную видеокарту.

## Что делает

Диспетчер `start_combined.sh` определяет GPU пода и запускает подходящий
combined-скрипт. При первом старте — ставит всё с нуля; при перезапуске пода —
видит уже установленные приложения и сразу переходит к запуску сервисов.

### Файлы репозитория

| Файл | Роль |
|------|------|
| `start_combined.sh` | Точка входа. Детектит GPU, скачивает и запускает нужный combined-скрипт. |
| `RTX5090_combined.sh` | Установка/запуск для **Blackwell** (RTX 5090, 50-серия, RTX PRO, B-серия). |
| `RTX4090_combined.sh` | Установка/запуск для **Ada** (RTX 4090, L40/L4) и **Legacy** (H100/A100/3090…). |

### Профиль GPU → скрипт → стек

| Профиль | Видеокарты | Скрипт | Базовый образ | PyTorch |
|---------|-----------|--------|---------------|---------|
| `blackwell` | RTX 5090/5080/5070…, RTX PRO, B200/B300 | `RTX5090_combined.sh` | `runpod/pytorch:2.8.0-py3.11-cuda12.8.1-cudnn-devel-ubuntu22.04` | `2.8.0+cu128` |
| `ada` | RTX 4090/4080/4070…, L40/L40S/L4 | `RTX4090_combined.sh` | `runpod/pytorch:2.4.0-py3.11-cuda12.4.1-devel-ubuntu22.04` | `2.4.0+cu124` |
| `legacy` | H200/H100/A100/A6000, RTX 3090/2080… | `RTX4090_combined.sh` | `runpod/pytorch:2.4.0-py3.11-cuda12.4.1-devel-ubuntu22.04` | `2.4.0+cu124` |

## Использование

Укажи это как **Container Start Command** в RunPod (обязательно через `bash -c`):

```bash
bash -c 'cd /workspace && wget -q https://raw.githubusercontent.com/IhorBr-git/big_runpod_boss/refs/heads/test/start_combined.sh -O start_combined.sh && chmod +x start_combined.sh && ./start_combined.sh'
```

Выбери шаблон пода с базовым образом под свой профиль GPU (см. таблицу выше).
Остальное диспетчер сделает сам.

## Сервисы и порты

| Сервис | Порт | Примечания |
|--------|------|-----------|
| AUTOMATIC1111 WebUI | `3000` | аргументы: `--opt-sdp-attention --no-half-vae --api --theme=dark` |
| ComfyUI | `8188` | запуск через сгенерированный `run_gpu.sh` (`--listen --enable-cors-header '*'`) |
| File Browser | `8080` | логин по умолчанию `admin` / `adminadmin11` |
| RunPod handler | — | `/start.sh` (SSH, Jupyter Lab, nginx) |

## Поведение при перезапуске

Оба приложения лежат в `/workspace` (постоянный сетевой volume). Если
`/workspace/stable-diffusion-webui` **и** `/workspace/ComfyUI` уже существуют —
установка пропускается, выполняется только `start_services`. Кастом-ноды и модели
переживают перезапуск.

## Общий каталог моделей

Все модели сводятся в `/workspace/models` и подкладываются симлинками и в A1111,
и в ComfyUI — единая копия на оба приложения (checkpoints, loras, vae, controlnet,
embeddings, …).

## Переменные окружения

| Переменная | Действие |
|------------|----------|
| `GPU_PROFILE=blackwell\|ada\|legacy` | Пропустить автодетект, форсировать профиль. |
| `REPO_BASE=<url>` | Сменить базовый URL загрузки скриптов (по умолчанию ветка `test`). |
| `FORCE_FULL_INSTALL=1` | Полная переустановка, даже если приложения уже есть в `/workspace`. |

## Файлы, создаваемые на поде (в репозитории их нет)

`run_gpu.sh`, `webui-user.sh`, `a1111-pip-constraints.txt`,
`extensions/vram-guard/` (кнопки Unload/Load VRAM для A1111),
`.filebrowser.db`.

## Заметки

- Combined-скрипты **самостоятельно чинят PyTorch-стек ComfyUI** (cuDNN,
  рассинхрон ABI torch/torchvision) при перезапуске.
- **Кастом-ноды ComfyUI этими скриптами не задаются** — их ставят вручную через
  ComfyUI-Manager, они лежат в `/workspace/ComfyUI/custom_nodes`. Именно тяжёлые
  или битые ноды там — обычная причина медленного старта ComfyUI.
