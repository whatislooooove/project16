#include <amxmodx>
#include <amxmisc>

#define PLUGIN_NAME    "PROJECT 1.6 Admin"
#define PLUGIN_VERSION "1.0.0"
#define PLUGIN_AUTHOR  "PROJECT 1.6"

new g_pBotQuota;
new g_pYbQuota;

public plugin_init()
{
    register_plugin(PLUGIN_NAME, PLUGIN_VERSION, PLUGIN_AUTHOR);

    // Количество ботов, которое будет восстанавливаться через меню.
    // Можно переопределить в server.cfg:
    // project_bot_quota "23"
    g_pBotQuota = register_cvar("project_bot_quota", "23");

    // YaPB quota.
    g_pYbQuota = get_cvar_pointer("yb_quota");

    // Добавляем пункт в стандартный amxmodmenu.
    // Флаг ADMIN_MENU = "u", как у стандартного меню AMX Mod X.
    AddMenuItem(
        "Управление ботами",
        "project_botmenu",
        ADMIN_MENU,
        "PROJECT 1.6 Admin"
    );

    // Также оставляем отдельную команду для быстрого открытия меню.
    register_clcmd(
        "project_botmenu",
        "cmd_project_botmenu",
        ADMIN_MENU,
        "Открыть меню управления ботами"
    );
}

public cmd_project_botmenu(id, level, cid)
{
    if (!cmd_access(id, level, cid, 1))
    {
        return PLUGIN_HANDLED;
    }

    show_bot_menu(id);
    return PLUGIN_HANDLED;
}

show_bot_menu(id)
{
    new menu = menu_create(
        "PROJECT 1.6 - Управление ботами",
        "bot_menu_handler"
    );

    new quota[8];
    get_pcvar_string(g_pBotQuota, quota, charsmax(quota));

    new item[64];

    formatex(item, charsmax(item), "Убрать всех ботов");
    menu_additem(menu, item, "0");

    formatex(item, charsmax(item), "Вернуть ботов (%s)", quota);
    menu_additem(menu, item, "1");

    menu_display(id, menu);
}

public bot_menu_handler(id, menu, item)
{
    if (item == MENU_EXIT)
    {
        menu_destroy(menu);
        return PLUGIN_HANDLED;
    }

    new info[8];
    new access;
    new callback;

    menu_item_getinfo(
        menu,
        item,
        access,
        info,
        charsmax(info),
        "",
        0,
        callback
    );

    if (equal(info, "0"))
    {
        remove_all_bots(id);
    }
    else if (equal(info, "1"))
    {
        restore_bots(id);
    }

    menu_destroy(menu);
    return PLUGIN_HANDLED;
}

remove_all_bots(id)
{
    if (!set_yb_quota(0))
    {
        client_print(id, print_chat, "[PROJECT 1.6] YaPB не найден.");
        return;
    }

    client_print(id, print_chat, "[PROJECT 1.6] Все боты убраны.");
    log_amx("Admin %n removed all YaPB bots.", id);
}

restore_bots(id)
{
    new quota = get_pcvar_num(g_pBotQuota);

    if (quota < 0)
    {
        quota = 0;
    }

    if (quota > 32)
    {
        quota = 32;
    }

    if (!set_yb_quota(quota))
    {
        client_print(id, print_chat, "[PROJECT 1.6] YaPB не найден.");
        return;
    }

    client_print(
        id,
        print_chat,
        "[PROJECT 1.6] Восстановлено количество ботов: %d.",
        quota
    );

    log_amx(
        "Admin %n restored YaPB bot quota to %d.",
        id,
        quota
    );
}

bool:set_yb_quota(quota)
{
    if (g_pYbQuota <= 0)
    {
        // Запасной вариант: отправляем команду серверу.
        server_cmd("yb_quota %d", quota);
        server_exec();

        // YaPB должен применить команду, поэтому считаем операцию успешной.
        return true;
    }

    set_pcvar_num(g_pYbQuota, quota);
    return true;
}
