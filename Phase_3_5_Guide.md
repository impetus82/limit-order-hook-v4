# Phase 3.5 — Live Interaction Scripts & Static Analysis

**Дата:** Февраль 2026  
**Проект:** Uniswap V4 Limit Orders Hook  
**Окружение:** MacBook Air (Apple Silicon), Foundry, Python 3.12 (pyenv)  
**Prerequisites:** Phase 3.4 complete, hook deployed at `0xE96fDfF54e9eD65E22e00fe57C425348dd58c088`

---

## 1. Файл: `script/InteractSepolia.s.sol`

Скрипт содержит 4 отдельных контракта (каждый запускается независимо):

| Контракт | Действие | Broadcast? |
|----------|----------|------------|
| `CreateOrder` | Mint TTA → approve hook → createLimitOrder | Да |
| `ExecuteSwap` | Deploy PoolSwapTest → mint TTB → swap TTB→TTA | Да |
| `CancelOrder` | Отмена ордера по ORDER_ID | Да |
| `ReadStatus` | Чтение состояния (ордера, балансы) | Нет (view) |

Захардкоженные адреса из Phase 3.4:
- Hook: `0xE96fDfF54e9eD65E22e00fe57C425348dd58c088`
- Token0 (TTA): `0x388D28a3D9aFcBdaeb97a359FC67A0B53fC0146E`
- Token1 (TTB): `0xa913a8019dd32691d7a9316a3d6cB75BA3904325`
- PoolManager: `0xE03A1074c86CFeDd5C142C4F04F1a1536e203543`

---

## 2. Terminal Commands (zsh, macOS)

### Подготовка

```bash
cd ~/projects/limit-order-hook-v4
source .env
 
# Проверка: env переменные на месте
echo "RPC: $SEPOLIA_RPC_URL"
echo "Key present: $([ -n "$PRIVATE_KEY" ] && echo YES || echo NO)"

# Проверка: тесты проходят
forge test -vv --summary
```

### Action 1: Создать ордер

```bash
# Dry-run (симуляция, без траты газа)
forge script script/InteractSepolia.s.sol:CreateOrder \
  --rpc-url $SEPOLIA_RPC_URL -vvvv

# Реальная транзакция
forge script script/InteractSepolia.s.sol:CreateOrder \
  --rpc-url $SEPOLIA_RPC_URL --broadcast -vvvv
```

Что произойдёт:
1. Минтит 10 TTA на deployer
2. Approve 10 TTA для hook
3. Создаёт ордер: продать 10 TTA когда цена >= 1.01

### Action 2: Выполнить своп (триггер ордеров)

```bash
# Dry-run
forge script script/InteractSepolia.s.sol:ExecuteSwap \
  --rpc-url $SEPOLIA_RPC_URL -vvvv

# Реальная транзакция
forge script script/InteractSepolia.s.sol:ExecuteSwap \
  --rpc-url $SEPOLIA_RPC_URL --broadcast -vvvv
```

Что произойдёт:
1. Деплоит PoolSwapTest (нет каноничного на Sepolia)
2. Минтит 50 TTB на deployer
3. Свопает 50 TTB → TTA (цена token0 растёт)
4. Hook `beforeSwap` проверяет ордера и исполняет eligible

### Action 3: Отмена ордера

```bash
# Отменить ордер #0
ORDER_ID=0 forge script script/InteractSepolia.s.sol:CancelOrder \
  --rpc-url $SEPOLIA_RPC_URL --broadcast -vvvv

# Отменить ордер #3
ORDER_ID=3 forge script script/InteractSepolia.s.sol:CancelOrder \
  --rpc-url $SEPOLIA_RPC_URL --broadcast -vvvv
```

### Utility: Чтение статуса (без газа)

```bash
forge script script/InteractSepolia.s.sol:ReadStatus \
  --rpc-url $SEPOLIA_RPC_URL -vvvv
```

### Альтернатива: `cast` для быстрых проверок

```bash
# Проверить конкретный ордер
cast call $HOOK_ADDRESS \
  "getOrder(uint256)(address,uint96,uint96,address,address,uint128,uint64,bool,bool)" \
  0 --rpc-url $SEPOLIA_RPC_URL

# Баланс TTA у deployer
cast call 0x388D28a3D9aFcBdaeb97a359FC67A0B53fC0146E \
  "balanceOf(address)(uint256)" \
  $(cast wallet address --private-key $PRIVATE_KEY) \
  --rpc-url $SEPOLIA_RPC_URL

# Количество созданных ордеров
cast call $HOOK_ADDRESS \
  "nextOrderId()(uint256)" \
  --rpc-url $SEPOLIA_RPC_URL

# Slot0 пула (текущая цена)
# Для этого нужен PoolId — сложнее через cast, проще через ReadStatus
```

---

## 3. Static Analysis: Slither на macOS

### Установка

```bash
# Через pyenv (Python 3.12 уже установлен)
pip3 install slither-analyzer --break-system-packages
# Или если через pyenv:
pip install slither-analyzer

# Проверка
slither --version

# Также нужен solc (Slither использует его для компиляции)
# Foundry уже ставит solc, но Slither может не найти
# Установить явно:
pip install solc-select
solc-select install 0.8.26
solc-select use 0.8.26
```

### Запуск

```bash
cd ~/projects/limit-order-hook-v4

# Базовый запуск (Foundry проект)
slither . --foundry-compile-all

# Если Slither жалуется на remappings:
slither . --solc-remaps "$(cat remappings.txt | tr '\n' ' ')"

# Только критичные находки
slither . --foundry-compile-all --filter-paths "test/,script/,lib/"

# JSON отчёт
slither . --foundry-compile-all --json slither-report.json
```

### Ожидаемые предупреждения (симуляция отчёта)

Основываясь на текущем коде `LimitOrderHook.sol`, Slither скорее всего выдаст:

**HIGH / MEDIUM:**

| # | Detector | Описание | Нужно ли исправлять? |
|---|----------|----------|---------------------|
| 1 | `calls-loop` | `safeTransfer` / `settle` / `take` вызываются внутри цикла в `_tryExecuteOrders` | ⚠️ **Известно.** Это by design — gas metering (`GAS_LIMIT_PER_ORDER`) защищает от OOG. Но стоит добавить NatSpec комментарий для аудиторов. |
| 2 | `reentrancy-eth` | `_executeOrderInBeforeSwap` вызывает внешние контракты (poolManager.swap, settle, take) до обновления состояния | ⚠️ **False positive.** `isExecuting` guard + `nonReentrant` на entry points. Но Slither не понимает custom guards. |
| 3 | `arbitrary-send-erc20` | `safeTransferFrom(msg.sender, ...)` в `createLimitOrder` | ✅ **OK.** Это нормальная custody модель. |

**LOW / INFORMATIONAL:**

| # | Detector | Описание | Действие |
|---|----------|----------|----------|
| 4 | `solc-version` | Pragm `^0.8.24` (floating) | 🔧 Для mainnet: зафиксировать `pragma solidity 0.8.26;` |
| 5 | `low-level-calls` | Возможно через v4-core internals | ✅ Ignore — это код зависимостей |
| 6 | `missing-zero-check` | Constructor не проверяет `_poolManager != address(0)` | 🔧 Добавить check (5 секунд) |
| 7 | `naming-convention` | `isExecuting` (mixed-case bool) vs screaming snake | ✅ OK — наша конвенция |
| 8 | `unused-return` | Возвращаемые значения из `poolManager.swap()` | ✅ Используются (swapDelta) |
| 9 | `timestamp` | `block.timestamp` в `createdAt` | ✅ OK — информационное поле |
| 10 | `too-many-digits` | Адреса в скриптах | ✅ Ignore — только в scripts |

**Рекомендация по исправлениям перед mainnet:**

1. **Зафиксировать solc версию:** `pragma solidity 0.8.26;` (не `^0.8.24`)
2. **Zero-address check в constructor:** `require(address(_poolManager) != address(0))`
3. **Добавить `// slither-disable-next-line calls-loop`** перед циклом в `_tryExecuteOrders`
4. **Добавить `// slither-disable-next-line reentrancy-eth`** в `_executeOrderInBeforeSwap` с комментарием про `isExecuting` guard

---

## 4. Manual Verification Plan (E2E на Sepolia)

### Полный сценарий тестирования:

```
Шаг 1: ReadStatus     — проверить начальное состояние (0 ордеров)
Шаг 2: CreateOrder     — создать ордер (sell 10 TTA @ price >= 1.01)
Шаг 3: ReadStatus     — проверить: ордер #0 существует, isFilled=false
Шаг 4: ExecuteSwap    — своп 50 TTB→TTA (двигаем цену вверх)
Шаг 5: ReadStatus     — проверить: ордер #0 isFilled=true, alice получила TTB
Шаг 6: CreateOrder     — создать еще один ордер (#1)
Шаг 7: CancelOrder    — отменить ордер #1 (ORDER_ID=1)
Шаг 8: ReadStatus     — проверить: ордер #1 отменён, токены возвращены
```

### Команды для полного прогона:

```bash
# 0. Подготовка
cd ~/projects/limit-order-hook-v4 && source .env
export HOOK_ADDRESS=0xE96fDfF54e9eD65E22e00fe57C425348dd58c088

# 1. Начальное состояние
forge script script/InteractSepolia.s.sol:ReadStatus \
  --rpc-url $SEPOLIA_RPC_URL -vvvv

# 2. Создать ордер
forge script script/InteractSepolia.s.sol:CreateOrder \
  --rpc-url $SEPOLIA_RPC_URL --broadcast -vvvv

# 3. Проверить ордер создан
forge script script/InteractSepolia.s.sol:ReadStatus \
  --rpc-url $SEPOLIA_RPC_URL -vvvv

# 4. Своп (триггер)
forge script script/InteractSepolia.s.sol:ExecuteSwap \
  --rpc-url $SEPOLIA_RPC_URL --broadcast -vvvv

# 5. Проверить исполнение
forge script script/InteractSepolia.s.sol:ReadStatus \
  --rpc-url $SEPOLIA_RPC_URL -vvvv

# 6. Второй ордер
forge script script/InteractSepolia.s.sol:CreateOrder \
  --rpc-url $SEPOLIA_RPC_URL --broadcast -vvvv

# 7. Отмена
ORDER_ID=1 forge script script/InteractSepolia.s.sol:CancelOrder \
  --rpc-url $SEPOLIA_RPC_URL --broadcast -vvvv

# 8. Финальный статус
forge script script/InteractSepolia.s.sol:ReadStatus \
  --rpc-url $SEPOLIA_RPC_URL -vvvv
```

### Верификация результатов на Etherscan:

```bash
# Открыть hook в браузере
open "https://sepolia.etherscan.io/address/0xE96fDfF54e9eD65E22e00fe57C425348dd58c088"

# Проверить транзакции — должны быть:
# - createLimitOrder tx
# - swap tx (через PoolSwapTest)
# - cancelOrder tx
```

---

## 5. Возможные проблемы и решения

| Проблема | Причина | Решение |
|----------|---------|---------|
| `EvmError: OutOfFund` | Мало Sepolia ETH | Google Cloud Faucet / Alchemy Faucet |
| `EvmError: Revert` на createOrder | Approve не прошёл или amount=0 | Проверить approve tx, убедиться что mint сработал |
| Своп не триггерит ордер | Цена не дошла до triggerPrice | Увеличить SWAP_AMOUNT (100 или 500 ether) |
| `SlippageExceeded` при исполнении | Низкая ликвидность в пуле | Добавить больше liquidity через SetupSepolia |
| Slither не находит solc | Не установлен через solc-select | `solc-select install 0.8.26 && solc-select use 0.8.26` |
| Slither не понимает remappings | Foundry remappings format | `slither . --solc-remaps "$(cat remappings.txt)"` |

---

## 6. Git Workflow

```bash
# После успешного тестирования
git add script/InteractSepolia.s.sol
git commit -m "feat(Phase 3.5): InteractSepolia script for live testnet testing

- CreateOrder: mint + approve + createLimitOrder
- ExecuteSwap: deploy PoolSwapTest + swap to trigger fills
- CancelOrder: cancel by ORDER_ID env var
- ReadStatus: view-only order/balance checker

Addresses hardcoded from Phase 3.4 deployment"

git push origin main
```

---

## 7. Next Steps после Phase 3.5

| # | Задача | Приоритет | Оценка |
|---|--------|-----------|--------|
| 1 | Fix Owner (initialOwner в constructor) | 🔴 HIGH | 30 мин |
| 2 | Запустить Slither, исправить findings | 🟡 MEDIUM | 1-2 часа |
| 3 | Frontend MVP (React + wagmi) | 🟡 MEDIUM | 2-3 дня |
| 4 | Mainnet deploy (с fixed Ownable) | 🔴 HIGH | 1 час |
| 5 | try/catch в execution loop | 🟡 MEDIUM | 2 часа |