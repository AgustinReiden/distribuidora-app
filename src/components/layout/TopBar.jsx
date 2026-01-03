import React from 'react';
import { Menu } from 'lucide-react';
import NotificationCenter from './NotificationCenter';

export default function TopBar({
  titulo,
  onToggleSidebar,
  sidebarColapsado,
  notifications,
  onMarkAsRead,
  onMarkAllAsRead,
  onRemoveNotification,
  onClearNotifications,
  unreadCount
}) {
  return (
    <header
      className={`fixed top-0 right-0 h-16 bg-white dark:bg-gray-800 border-b dark:border-gray-700 shadow-sm z-30 flex items-center justify-between px-6 transition-all duration-300 ${
        sidebarColapsado ? 'left-20' : 'left-64'
      }`}
    >
      <div className="flex items-center space-x-4">
        <button
          onClick={onToggleSidebar}
          className="p-2 rounded-lg hover:bg-gray-100 dark:hover:bg-gray-700 transition-colors lg:hidden"
          aria-label="Toggle menu"
        >
          <Menu className="w-5 h-5 text-gray-600 dark:text-gray-300" />
        </button>
        <h2 className="text-lg font-semibold text-gray-800 dark:text-white capitalize">
          {titulo}
        </h2>
      </div>

      <div className="flex items-center space-x-3">
        <NotificationCenter
          notifications={notifications}
          onMarkAsRead={onMarkAsRead}
          onMarkAllAsRead={onMarkAllAsRead}
          onRemove={onRemoveNotification}
          onClearAll={onClearNotifications}
          unreadCount={unreadCount}
        />
      </div>
    </header>
  );
}
